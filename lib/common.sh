#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# DGX Spark Llama Cluster — Shared Functions
# Sourced by all setup scripts. Do not run directly.
# ─────────────────────────────────────────────────────────────

# ── Colors ───────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ── Logging ──────────────────────────────────────────────────
log()   { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
warn()  { echo -e "${YELLOW}[WARNING]${NC} $1"; }

# ── Guards ───────────────────────────────────────────────────
require_root() {
    [[ $EUID -eq 0 ]] || error "This script must be run as root (use sudo)"
}

# ── User detection (resolves real user even under sudo) ──────
detect_user() {
    ACTUAL_USER="${SUDO_USER:-$USER}"
    ACTUAL_HOME=$(eval echo "~$ACTUAL_USER")
    MODELS_DIR="$ACTUAL_HOME/.lmstudio/models"
}

# ── Node argument parsing ────────────────────────────────────
# Sets: NODE_NUM, NODE_IP, NODE_IP2, PEER_IP, PEER_IP2, NODE_ROLE
parse_node_arg() {
    local usage="Usage: $0 --node <1-$NODE_COUNT>"
    NODE_NUM=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --node|-n) NODE_NUM="$2"; shift 2 ;;
            [0-9]*)    NODE_NUM="$1"; shift ;;
            -h|--help) echo "$usage"; exit 0 ;;
            *)         error "Unknown argument: $1\n$usage" ;;
        esac
    done

    [[ -n "$NODE_NUM" ]] || error "Node number required.\n$usage"

    if [[ "$NODE_NUM" -lt 1 || "$NODE_NUM" -gt "$NODE_COUNT" ]] 2>/dev/null; then
        error "Node must be 1-$NODE_COUNT.\n$usage\nSet NODE_COUNT in cluster.conf to add nodes."
    fi

    # Look up this node's IPs via indirect variable reference
    local ip_var="NODE${NODE_NUM}_IP"
    local ip2_var="NODE${NODE_NUM}_IP2"
    NODE_IP="${!ip_var}"
    NODE_IP2="${!ip2_var}"

    [[ -n "$NODE_IP" ]] || error "NODE${NODE_NUM}_IP not defined in cluster.conf"

    # Role: node 1 = head, all others = worker
    if [[ "$NODE_NUM" -eq 1 ]]; then
        NODE_ROLE="head"
        # Default peer = node 2 (for RDMA testing convenience)
        PEER_IP="${NODE2_IP:-}"
        PEER_IP2="${NODE2_IP2:-}"
    else
        NODE_ROLE="worker"
        # Workers peer with head
        PEER_IP="$NODE1_IP"
        PEER_IP2="$NODE1_IP2"
    fi
}

# ── Multi-node helpers ───────────────────────────────────────

# Get primary IP for node N
get_node_ip() {
    local var="NODE${1}_IP"
    echo "${!var}"
}

# Get secondary IP for node N
get_node_ip2() {
    local var="NODE${1}_IP2"
    echo "${!var}"
}

# Build comma-separated RPC endpoint list from all workers
# e.g. "192.168.200.12:50052,192.168.200.13:50052"
get_worker_rpc_list() {
    local parts=()
    for ((n=2; n<=NODE_COUNT; n++)); do
        parts+=("$(get_node_ip "$n"):$RPC_PORT")
    done
    local IFS=','
    echo "${parts[*]}"
}

# Get all worker IPs as space-separated string
get_all_worker_ips() {
    local ips=()
    for ((n=2; n<=NODE_COUNT; n++)); do
        ips+=("$(get_node_ip "$n")")
    done
    echo "${ips[*]}"
}

# ── ConnectX-7 interface detection ───────────────────────────
# Sets: IFACE1, IFACE2
detect_mlx5_interfaces() {
    log "Detecting ConnectX-7 network interfaces..."

    local ALL_MLX
    ALL_MLX=$(ls -d /sys/class/net/*/device/driver 2>/dev/null | while read -r d; do
        readlink -f "$d" | grep -q mlx5 && basename "$(dirname "$(dirname "$d")")"
    done | sort)

    if [[ -z "$ALL_MLX" ]] && command -v ibdev2netdev &>/dev/null; then
        ALL_MLX=$(ibdev2netdev | awk '{print $5}' | sort)
    fi

    [[ -z "$ALL_MLX" ]] && error "No ConnectX network interfaces found. Check hardware."

    local -a ALL_ARR
    IFS=$'\n' read -r -d '' -a ALL_ARR <<< "$ALL_MLX" || true

    if [[ ${#ALL_ARR[@]} -gt 2 ]]; then
        log "Found ${#ALL_ARR[@]} mlx5 interfaces, filtering to active links..."
        local -a ACTIVE=()
        for iface in "${ALL_ARR[@]}"; do
            local carrier operstate
            carrier=$(cat "/sys/class/net/$iface/carrier" 2>/dev/null || echo "0")
            operstate=$(cat "/sys/class/net/$iface/operstate" 2>/dev/null || echo "down")
            if [[ "$carrier" = "1" || "$operstate" = "up" ]]; then
                ACTIVE+=("$iface")
            fi
        done
        if [[ ${#ACTIVE[@]} -ge 2 ]]; then
            IFACE1="${ACTIVE[0]}"; IFACE2="${ACTIVE[1]}"
        else
            warn "Only ${#ACTIVE[@]} active link(s). Using first 2 of all interfaces."
            IFACE1="${ALL_ARR[0]}"; IFACE2="${ALL_ARR[1]}"
        fi
    elif [[ ${#ALL_ARR[@]} -ge 2 ]]; then
        IFACE1="${ALL_ARR[0]}"; IFACE2="${ALL_ARR[1]}"
    else
        error "Expected 2 ConnectX interfaces, found ${#ALL_ARR[@]}: ${ALL_ARR[*]}"
    fi

    log "Using interfaces: $IFACE1, $IFACE2"
}

# ── RDMA device detection ───────────────────────────────────
# Sets: ACTIVE_RDMA_DEVICES (array)
detect_rdma_devices() {
    if [[ ! -d /sys/class/infiniband ]] || [[ -z "$(ls /sys/class/infiniband/ 2>/dev/null)" ]]; then
        error "No RDMA devices found. Run setup-rdma.sh first and reboot."
    fi

    ACTIVE_RDMA_DEVICES=()
    for dev in /sys/class/infiniband/*; do
        local dev_name
        dev_name=$(basename "$dev")
        for port_dir in "$dev"/ports/*; do
            if cat "$port_dir/state" 2>/dev/null | grep -q "ACTIVE"; then
                ACTIVE_RDMA_DEVICES+=("$dev_name")
                break
            fi
        done
    done

    [[ ${#ACTIVE_RDMA_DEVICES[@]} -eq 0 ]] && \
        error "No RDMA devices in ACTIVE state. Check cables: ibv_devinfo"

    log "Active RDMA devices: ${ACTIVE_RDMA_DEVICES[*]}"
}

# ── Primary RDMA network interface ──────────────────────────
# Sets: RDMA_NET_IFACE
detect_rdma_net_iface() {
    RDMA_NET_IFACE=""

    if command -v ibdev2netdev &>/dev/null; then
        RDMA_NET_IFACE=$(ibdev2netdev | grep "Up" | head -n1 | awk '{print $5}')
    fi

    if [[ -z "$RDMA_NET_IFACE" ]]; then
        for d in /sys/class/net/*/device/driver; do
            readlink -f "$d" 2>/dev/null | grep -q mlx5 && {
                local iface state
                iface=$(basename "$(dirname "$(dirname "$d")")")
                state=$(cat "/sys/class/net/$iface/operstate" 2>/dev/null)
                if [[ "$state" = "up" ]]; then
                    RDMA_NET_IFACE="$iface"
                    break
                fi
            }
        done
    fi

    if [[ -z "$RDMA_NET_IFACE" ]]; then
        warn "Could not auto-detect active RDMA interface, using first mlx5"
        RDMA_NET_IFACE=$(ls -d /sys/class/net/*/device/driver 2>/dev/null | while read -r d; do
            readlink -f "$d" | grep -q mlx5 && basename "$(dirname "$(dirname "$d")")" && break
        done)
    fi

    log "Primary RDMA interface: $RDMA_NET_IFACE"
}

# ── GPU detection ────────────────────────────────────────────
# Sets: GPU_COUNT, GPU_NAME
detect_gpu() {
    command -v nvidia-smi &>/dev/null || error "nvidia-smi not found. NVIDIA drivers not installed?"
    GPU_COUNT=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | wc -l)
    GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)
    log "Found $GPU_COUNT GPU(s): $GPU_NAME"
}

# ── CUDA toolkit detection ──────────────────────────────────
# Sets: CUDA_VERSION
detect_cuda() {
    if ! command -v nvcc &>/dev/null; then
        for cuda_path in /usr/local/cuda/bin /usr/local/cuda-13.0/bin /usr/local/cuda-13/bin; do
            if [[ -x "$cuda_path/nvcc" ]]; then
                export PATH="$cuda_path:$PATH"
                log "Found nvcc at: $cuda_path/nvcc"
                break
            fi
        done
        command -v nvcc &>/dev/null || error "nvcc not found. CUDA toolkit is required."
    fi
    CUDA_VERSION=$(nvcc --version | grep -oP 'release \K[0-9.]+')
    log "CUDA version: $CUDA_VERSION"
}

# ── Source cluster.conf relative to the calling script ───────
load_config() {
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[1]:-$0}")" && pwd)"
    local conf="$script_dir/cluster.conf"
    [[ -f "$conf" ]] || error "cluster.conf not found at $conf"
    # shellcheck source=../cluster.conf
    source "$conf"
}
