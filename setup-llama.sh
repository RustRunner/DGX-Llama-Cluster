#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# DGX Spark Llama Cluster — llama.cpp Setup
# Builds llama.cpp with CUDA + RPC and installs services.
# Node 1: server launch scripts + management tools
# Node 2+: RPC worker systemd service
# Usage: sudo ./setup-llama.sh --node <1-N>
# Run AFTER setup-rdma.sh + reboot
# ─────────────────────────────────────────────────────────────

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
load_config

require_root
detect_user
parse_node_arg "$@"

log "Starting llama.cpp setup for Node $NODE_NUM ($NODE_ROLE)"
log "User: $ACTUAL_USER | Home: $ACTUAL_HOME | Models: $MODELS_DIR"

#######################################
# Step 1: Verify RDMA Prerequisites
#######################################

log "Verifying RDMA prerequisites..."
detect_rdma_devices
detect_rdma_net_iface
detect_gpu
detect_cuda

#######################################
# Step 2: Install Build Dependencies
#######################################

log "Installing build dependencies..."
apt-get update -qq
apt-get install -y -qq git cmake build-essential libcurl4-openssl-dev

# ggml-rpc auto-enables native RDMA when libibverbs headers are present at cmake time.
# MLNX OFED ships these; only pull from apt if missing, to avoid clobbering OFED's libs.
if [[ ! -f /usr/include/infiniband/verbs.h ]]; then
    log "libibverbs headers missing — installing libibverbs-dev"
    apt-get install -y -qq libibverbs-dev
else
    log "libibverbs headers found (provided by MLNX OFED or system)"
fi

#######################################
# Step 3: Build llama.cpp from Source
#######################################

log "Building llama.cpp..."

# Step A: ensure a working tree exists, fetch latest refs
if [[ -d "$LLAMA_CPP_DIR" ]]; then
    log "Existing source at $LLAMA_CPP_DIR — fetching refs..."
    cd "$LLAMA_CPP_DIR"
    git fetch --all --quiet || warn "git fetch failed, will use whatever local refs exist"
else
    log "Cloning llama.cpp..."
    git clone "$LLAMA_CPP_REPO" "$LLAMA_CPP_DIR"
    cd "$LLAMA_CPP_DIR"
fi

# Step B: select the commit — pinned (LLAMA_CPP_COMMIT set) or track master
if [[ -n "${LLAMA_CPP_COMMIT:-}" ]]; then
    log "Pinning llama.cpp to LLAMA_CPP_COMMIT=$LLAMA_CPP_COMMIT"
    git checkout --quiet "$LLAMA_CPP_COMMIT" || \
        error "Cannot checkout pinned commit '$LLAMA_CPP_COMMIT' — verify the SHA exists in the fetched refs"
else
    git checkout --quiet master 2>/dev/null || true
    git pull --ff-only --quiet || {
        warn "git pull failed, doing a fresh clone..."
        cd /opt
        rm -rf "$LLAMA_CPP_DIR"
        git clone "$LLAMA_CPP_REPO" "$LLAMA_CPP_DIR"
        cd "$LLAMA_CPP_DIR"
    }
fi

LLAMA_COMMIT=$(git rev-parse --short HEAD)
log "llama.cpp commit: $LLAMA_COMMIT"

log "Configuring cmake..."

# ARM CPU tuning — override ARM_NATIVE_FLAG (the internal variable llama.cpp's
# ggml-cpu CMakeLists uses for both feature probes and the actual ARCH_FLAGS).
# Without this, auto-detect resolves to -mcpu=native, which on Grace + GCC 13
# produces baseline armv8-a (no DotProd/SVE2/I8MM/BF16/FP16) because GCC's native
# detection doesn't yet identify the Grace CPU profile.
# Also pushing the same flag into CMAKE_*_FLAGS as belt-and-suspenders for any
# code path that bypasses ARM_NATIVE_FLAG.
ARM_CPU_FLAG=()
if [[ "$(uname -m)" = "aarch64" ]] && [[ -n "${ARM_CPU:-}" ]]; then
    ARM_CPU_FLAG=(
        -DARM_NATIVE_FLAG="-mcpu=$ARM_CPU"
        -DCMAKE_C_FLAGS="-mcpu=$ARM_CPU"
        -DCMAKE_CXX_FLAGS="-mcpu=$ARM_CPU"
    )
    log "ARM CPU tuning: -mcpu=$ARM_CPU (via ARM_NATIVE_FLAG override)"
fi

cmake -B build \
    -DGGML_CUDA=ON \
    -DGGML_RPC=ON \
    -DGGML_CURL=ON \
    -DCMAKE_CUDA_ARCHITECTURES="$CUDA_ARCH" \
    -DCMAKE_BUILD_TYPE=Release \
    "${ARM_CPU_FLAG[@]}"

log "Compiling (this will take several minutes)..."
cmake --build build --config Release -j"$(nproc)"

[[ -x build/bin/llama-server ]] || error "Build failed: llama-server not found"
[[ -x build/bin/rpc-server ]]   || error "Build failed: rpc-server not found"

log "Build successful"

if ldd build/bin/llama-server | grep -q cuda; then
    log "CUDA linkage verified"
else
    warn "CUDA not detected in binary. GPU offloading may not work."
fi

# RDMA linkage — ggml-rpc auto-uses RDMA at runtime when libibverbs is linked in.
# Without it, RPC falls back to TCP (still works over RoCE, just higher latency / lower throughput).
if ldd build/bin/rpc-server | grep -q ibverbs; then
    log "${GREEN}RDMA linkage verified — rpc-server will use native RDMA${NC}"
else
    warn "RDMA NOT linked into rpc-server — RPC will fall back to TCP over RoCE"
    warn "  Install libibverbs-dev (or MLNX OFED userspace) and re-run setup-llama.sh"
fi

#######################################
# Step 4: Install Binaries
#######################################

log "Installing binaries to /usr/local/bin/..."
ln -sf "$LLAMA_CPP_DIR/build/bin/llama-server" /usr/local/bin/llama-server
ln -sf "$LLAMA_CPP_DIR/build/bin/llama-cli" /usr/local/bin/llama-cli
ln -sf "$LLAMA_CPP_DIR/build/bin/rpc-server" /usr/local/bin/rpc-server

llama-server --version 2>/dev/null && log "llama-server installed" || log "llama-server linked"
log "llama-cli and rpc-server also installed"

#######################################
# Step 5: Pre-compute worker lists
#######################################

# Build space-separated worker IP string for embedding in scripts
WORKER_IPS_STR=""
WORKER_SSH_LINES=""
for ((n=2; n<=NODE_COUNT; n++)); do
    ip_var="NODE${n}_IP"
    ip="${!ip_var}"
    [[ -n "$WORKER_IPS_STR" ]] && WORKER_IPS_STR+=" "
    WORKER_IPS_STR+="$ip"
    WORKER_SSH_LINES+="    ssh $ip 'sudo systemctl start llama-rpc'"$'\n'
done
WORKER_COUNT=$((NODE_COUNT - 1))

log "Cluster: $NODE_COUNT nodes ($WORKER_COUNT worker(s): $WORKER_IPS_STR)"

#######################################
# Step 6: Node-Specific Setup
#######################################

case "$NODE_NUM" in

# ═════════════════════════════════════
# NODE 1 — Head/Server
# ═════════════════════════════════════
1)
    log "Setting up Node 1 (Head/Server) launch scripts..."

    # ── Multi-node cluster launcher ─────────────────────────
    cat > /usr/local/bin/llama-cluster-start.sh << LAUNCHEOF
#!/bin/bash
#######################################
# llama.cpp Multi-Node Cluster Launcher
# Checks all RPC workers and launches with reachable ones
#######################################

NODE1_IP="$NODE1_IP"
WORKER_IPS=($WORKER_IPS_STR)
RPC_PORT="$RPC_PORT"
SERVER_PORT="$SERVER_PORT"
if [ -n "\$SUDO_USER" ]; then
    MODELS_DIR="/home/\$SUDO_USER/.lmstudio/models"
else
    MODELS_DIR="\$HOME/.lmstudio/models"
fi

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

MODEL="\${1:-}"
if [ -z "\$MODEL" ]; then
    echo -e "\${YELLOW}Usage: llama-cluster-start.sh <model.gguf> [options]\${NC}"
    echo ""
    echo "Models directory: \$MODELS_DIR"
    echo ""
    echo "Available GGUF models:"
    find "\$MODELS_DIR" -name "*.gguf" ! -name "*-of-*" -printf "  %p\n" 2>/dev/null
    find "\$MODELS_DIR" -name "*-00001-of-*.gguf" -printf "  %p  (split)\n" 2>/dev/null
    find "\$MODELS_DIR" -name "*.gguf" \\( ! -name "*-of-*" -o -name "*-00001-of-*" \\) 2>/dev/null | head -1 | grep -q . || echo "  (none found)"
    echo ""
    echo "Options (pass after model path):"
    echo "  -c, --ctx-size N       Context size (default: 200000)"
    echo "  -ngl N                 GPU layers (default: 999 = all)"
    echo "  --port N               API port (default: $SERVER_PORT)"
    echo "  -np, --parallel N      Concurrent request slots (default: 1, splits context)"
    echo "  -ctk TYPE              KV cache key type: f16, q8_0, q4_0 (default: q8_0)"
    echo "  -ctv TYPE              KV cache value type (default: q8_0)"
    echo "  -t N                   CPU threads (default: 16)"
    echo ""
    echo "API: http://\$NODE1_IP:\$SERVER_PORT/v1"
    exit 1
fi

shift
EXTRA_ARGS="\$@"

# Check each RPC worker
echo -e "\${GREEN}Checking RPC workers (\${#WORKER_IPS[@]} configured)...\${NC}"
RPC_ENDPOINTS=()
for wip in "\${WORKER_IPS[@]}"; do
    if timeout 3 bash -c "echo >/dev/tcp/\$wip/\$RPC_PORT" 2>/dev/null; then
        echo "  \$wip:\$RPC_PORT — reachable"
        RPC_ENDPOINTS+=("\$wip:\$RPC_PORT")
    else
        echo -e "\${RED}  \$wip:\$RPC_PORT — NOT reachable\${NC}"
    fi
done

RPC_FLAG=""
if [ \${#RPC_ENDPOINTS[@]} -gt 0 ]; then
    # Build comma-separated list
    RPC_LIST=\$(IFS=','; echo "\${RPC_ENDPOINTS[*]}")
    RPC_FLAG="--rpc \$RPC_LIST"
    echo ""
    echo "  \${#RPC_ENDPOINTS[@]}/\${#WORKER_IPS[@]} worker(s) available"
else
    echo ""
    echo -e "\${RED}No RPC workers reachable.\${NC}"
    echo ""
    echo "  Start workers with: sudo systemctl start llama-rpc"
    echo ""
    read -p "Continue in single-node mode? (y/n): " -n 1 -r
    echo
    if [[ ! \$REPLY =~ ^[Yy]\$ ]]; then
        exit 1
    fi
    echo -e "\${YELLOW}Running in single-node mode\${NC}"
fi

# Auto-detect chat template override from upstream llama.cpp templates dir.
# Some community-quantized GGUFs ship chat templates that don't trigger
# llama.cpp's generalized auto-parser (e.g. MiniMax-M2.7 → tool calls leak as
# raw <minimax:tool_call> XML). Pointing at the canonical upstream template
# usually fixes it. We pick the longest-matching template name as a substring
# of the model basename, so e.g. "Qwen3-Coder" wins over "Qwen3" when both exist.
TEMPLATE_FLAG=""
TEMPLATES_DIR="/opt/llama.cpp/models/templates"
if [ -d "\$TEMPLATES_DIR" ]; then
    MODEL_NAME=\$(basename "\$MODEL" | sed -E 's/-(Q[0-9]+_[KMSL].*|f16|bf16|fp16).*//; s/\\.gguf\$//')
    BEST_TPL=""
    BEST_LEN=0
    for tpl in "\$TEMPLATES_DIR"/*.jinja; do
        [ -f "\$tpl" ] || continue
        TPL_BASE=\$(basename "\$tpl" .jinja)
        if echo "\$MODEL_NAME" | grep -qiF "\$TPL_BASE"; then
            TPL_LEN=\${#TPL_BASE}
            if [ "\$TPL_LEN" -gt "\$BEST_LEN" ]; then
                BEST_LEN=\$TPL_LEN
                BEST_TPL="\$tpl"
            fi
        fi
    done
    if [ -n "\$BEST_TPL" ]; then
        TEMPLATE_FLAG="--chat-template-file \$BEST_TPL"
    fi
fi

echo ""
echo -e "\${GREEN}Starting llama-server...\${NC}"
echo "  Model: \$MODEL"
echo "  RPC workers: \${RPC_FLAG:-none (single-node)}"
echo "  Chat template: \${BEST_TPL:-(GGUF embedded)}"
echo "  API: http://\$NODE1_IP:\$SERVER_PORT"
echo "  OpenAI API: http://\$NODE1_IP:\$SERVER_PORT/v1"
echo ""

exec llama-server \\
    --model "\$MODEL" \\
    --host 0.0.0.0 \\
    --port "\$SERVER_PORT" \\
    -ngl 999 \\
    -fa on \\
    --no-mmap \\
    --jinja \\
    -c 200000 \\
    -b 4096 \\
    -ub 4096 \\
    -ctk q8_0 \\
    -ctv q8_0 \\
    --parallel 1 \\
    -t 16 \\
    \$TEMPLATE_FLAG \\
    \$RPC_FLAG \\
    \$EXTRA_ARGS
LAUNCHEOF

    chmod +x /usr/local/bin/llama-cluster-start.sh

    # ── Single-node launcher ────────────────────────────────
    cat > /usr/local/bin/llama-local-start.sh << LOCALEOF
#!/bin/bash
#######################################
# llama.cpp Single-Node Launcher
# For models that fit in one DGX Spark (128GB)
#######################################

NODE1_IP="$NODE1_IP"
SERVER_PORT="$SERVER_PORT"
if [ -n "\$SUDO_USER" ]; then
    MODELS_DIR="/home/\$SUDO_USER/.lmstudio/models"
else
    MODELS_DIR="\$HOME/.lmstudio/models"
fi

MODEL="\${1:-}"
if [ -z "\$MODEL" ]; then
    echo "Usage: llama-local-start.sh <model.gguf> [options]"
    echo ""
    echo "Models directory: \$MODELS_DIR"
    echo ""
    echo "Available GGUF models:"
    find "\$MODELS_DIR" -name "*.gguf" ! -name "*-of-*" -printf "  %p\n" 2>/dev/null
    find "\$MODELS_DIR" -name "*-00001-of-*.gguf" -printf "  %p  (split)\n" 2>/dev/null
    find "\$MODELS_DIR" -name "*.gguf" \\( ! -name "*-of-*" -o -name "*-00001-of-*" \\) 2>/dev/null | head -1 | grep -q . || echo "  (none found)"
    echo ""
    exit 1
fi

shift

# Auto-detect chat template override (see llama-cluster-start.sh for details)
TEMPLATE_FLAG=""
TEMPLATES_DIR="/opt/llama.cpp/models/templates"
if [ -d "\$TEMPLATES_DIR" ]; then
    MODEL_NAME=\$(basename "\$MODEL" | sed -E 's/-(Q[0-9]+_[KMSL].*|f16|bf16|fp16).*//; s/\\.gguf\$//')
    BEST_TPL=""
    BEST_LEN=0
    for tpl in "\$TEMPLATES_DIR"/*.jinja; do
        [ -f "\$tpl" ] || continue
        TPL_BASE=\$(basename "\$tpl" .jinja)
        if echo "\$MODEL_NAME" | grep -qiF "\$TPL_BASE"; then
            TPL_LEN=\${#TPL_BASE}
            if [ "\$TPL_LEN" -gt "\$BEST_LEN" ]; then
                BEST_LEN=\$TPL_LEN
                BEST_TPL="\$tpl"
            fi
        fi
    done
    if [ -n "\$BEST_TPL" ]; then
        TEMPLATE_FLAG="--chat-template-file \$BEST_TPL"
        echo "Chat template override: \$(basename \$BEST_TPL .jinja)"
    fi
fi

exec llama-server \\
    --model "\$MODEL" \\
    --host 0.0.0.0 \\
    --port "\$SERVER_PORT" \\
    -ngl 999 \\
    -fa on \\
    --no-mmap \\
    --jinja \\
    -c 32768 \\
    -b 2048 \\
    -ub 512 \\
    --parallel 1 \\
    -t 16 \\
    \$TEMPLATE_FLAG \\
    "\$@"
LOCALEOF

    chmod +x /usr/local/bin/llama-local-start.sh

    # ── Cluster status (Node 1 perspective) ─────────────────
    cat > /usr/local/bin/cluster-status.sh << STATUSEOF
#!/bin/bash
NODE1_IP="$NODE1_IP"
WORKER_IPS=($WORKER_IPS_STR)
RPC_PORT="$RPC_PORT"
SERVER_PORT="$SERVER_PORT"

echo "=== llama.cpp Server ==="
if pgrep -x llama-server > /dev/null 2>&1; then
    echo "running (PID: \$(pgrep -x llama-server))"
else
    echo "not running"
fi
echo ""

echo "=== RPC Workers (\${#WORKER_IPS[@]} configured) ==="
for wip in "\${WORKER_IPS[@]}"; do
    if timeout 3 bash -c "echo >/dev/tcp/\$wip/\$RPC_PORT" 2>/dev/null; then
        echo "  \$wip:\$RPC_PORT — reachable"
    else
        echo "  \$wip:\$RPC_PORT — NOT reachable"
    fi
done
echo ""

echo "=== GPU Status ==="
nvidia-smi --query-gpu=name,memory.used,memory.total,utilization.gpu --format=csv,noheader 2>/dev/null || echo "nvidia-smi not available"
echo ""

echo "=== RDMA Link ==="
ibdev2netdev 2>/dev/null || echo "ibdev2netdev not available"
echo ""

echo "=== llama.cpp API ==="
if curl -s http://localhost:\$SERVER_PORT/health > /dev/null 2>&1; then
    echo "API running on port \$SERVER_PORT"
    echo ""
    echo "Models:"
    curl -s http://localhost:\$SERVER_PORT/v1/models 2>/dev/null | python3 -m json.tool 2>/dev/null || echo "  (could not parse)"
else
    echo "API not running"
fi
echo ""

echo "=== Worker Connectivity ==="
for wip in "\${WORKER_IPS[@]}"; do
    ping -c 1 -W 2 \$wip > /dev/null 2>&1 && echo "  \$wip — reachable" || echo "  \$wip — NOT reachable"
done
echo ""
STATUSEOF

    chmod +x /usr/local/bin/cluster-status.sh

    # ── Cluster stop ────────────────────────────────────────
    cat > /usr/local/bin/cluster-stop.sh << STOPEOF
#!/bin/bash
echo "Stopping llama-server..."
pkill -x llama-server 2>/dev/null && echo "  Stopped." || echo "  Not running."
echo ""
echo "RPC workers stay running (systemd services)."
echo "To stop them:"
STOPEOF
    # Append per-worker ssh lines
    for ((n=2; n<=NODE_COUNT; n++)); do
        ip_var="NODE${n}_IP"
        echo "echo \"  ssh ${!ip_var} 'sudo systemctl stop llama-rpc'\"" >> /usr/local/bin/cluster-stop.sh
    done

    chmod +x /usr/local/bin/cluster-stop.sh

    # ── Interactive start-everything ────────────────────────
    cat > /usr/local/bin/start-everything.sh << STARTEOF
#!/bin/bash
#######################################
# Interactive cluster startup
# Checks all RPC workers, lists models, launches
#######################################

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

WORKER_IPS=($WORKER_IPS_STR)
RPC_PORT="$RPC_PORT"
if [ -n "\$SUDO_USER" ]; then
    MODELS_DIR="/home/\$SUDO_USER/.lmstudio/models"
else
    MODELS_DIR="\$HOME/.lmstudio/models"
fi

echo -e "\${GREEN}=== DGX Spark llama.cpp Cluster ===\${NC}"
echo ""

# Step 1: Check all RPC workers
echo -e "\${GREEN}[1/3] Checking RPC workers (\${#WORKER_IPS[@]} configured)...\${NC}"
AVAILABLE=0
for wip in "\${WORKER_IPS[@]}"; do
    if timeout 3 bash -c "echo >/dev/tcp/\$wip/\$RPC_PORT" 2>/dev/null; then
        echo "  \$wip:\$RPC_PORT — running"
        AVAILABLE=\$((AVAILABLE + 1))
    else
        echo -e "  \${YELLOW}\$wip:\$RPC_PORT — not reachable\${NC}"
    fi
done

if [ \$AVAILABLE -eq 0 ]; then
    echo ""
    echo -e "  \${YELLOW}No workers reachable. Waiting 15 seconds...\${NC}"
    sleep 15
    for wip in "\${WORKER_IPS[@]}"; do
        if timeout 3 bash -c "echo >/dev/tcp/\$wip/\$RPC_PORT" 2>/dev/null; then
            AVAILABLE=\$((AVAILABLE + 1))
        fi
    done
    if [ \$AVAILABLE -eq 0 ]; then
        echo -e "  \${RED}Still no workers. Will launch single-node.\${NC}"
    else
        echo "  \$AVAILABLE worker(s) now available"
    fi
fi

RPC_AVAILABLE=false
[ \$AVAILABLE -gt 0 ] && RPC_AVAILABLE=true

# Step 2: Select model
echo ""
echo -e "\${GREEN}[2/3] Select a model\${NC}"
echo ""

MODELS=()
while IFS= read -r f; do
    MODELS+=("\$f")
done < <(find "\$MODELS_DIR" -name "*.gguf" \\( ! -name "*-of-*" -o -name "*-00001-of-*" \\) 2>/dev/null | sort)

if [ \${#MODELS[@]} -eq 0 ]; then
    echo -e "\${RED}No GGUF models found in \$MODELS_DIR\${NC}"
    exit 1
fi

for i in "\${!MODELS[@]}"; do
    SHORT=\$(echo "\${MODELS[\$i]}" | sed "s|\$MODELS_DIR/||")
    if [[ "\${MODELS[\$i]}" == *"-00001-of-"* ]]; then
        echo -e "  \${CYAN}\$((i+1)))\${NC} \$SHORT  (split)"
    else
        echo -e "  \${CYAN}\$((i+1)))\${NC} \$SHORT"
    fi
done

echo ""
read -p "Select model [1-\${#MODELS[@]}]: " MODEL_NUM

if ! [[ "\$MODEL_NUM" =~ ^[0-9]+\$ ]] || [ "\$MODEL_NUM" -lt 1 ] || [ "\$MODEL_NUM" -gt \${#MODELS[@]} ]; then
    echo -e "\${RED}Invalid selection.\${NC}"
    exit 1
fi

SELECTED="\${MODELS[\$((MODEL_NUM-1))]}"
echo "  Selected: \$SELECTED"

# Step 3: Launch
echo ""
echo -e "\${GREEN}[3/3] Launch\${NC}"
echo ""
read -p "Context size (default: 200000): " CTX_SIZE
CTX_SIZE="\${CTX_SIZE:-200000}"
echo ""

if [ "\$RPC_AVAILABLE" = true ]; then
    echo -e "Launching with \${CYAN}llama-cluster-start.sh\${NC} (multi-node)..."
    echo ""
    exec llama-cluster-start.sh "\$SELECTED" -c "\$CTX_SIZE"
else
    echo -e "Launching with \${CYAN}llama-local-start.sh\${NC} (single-node)..."
    echo ""
    exec llama-local-start.sh "\$SELECTED" -c "\$CTX_SIZE"
fi
STARTEOF

    chmod +x /usr/local/bin/start-everything.sh

    # ── Stop everything ─────────────────────────────────────
    cat > /usr/local/bin/stop-everything.sh << STOPALLEOF
#!/bin/bash
echo "Stopping llama-server..."
pkill -x llama-server 2>/dev/null && echo "  Stopped." || echo "  Not running."
echo ""
echo "To stop workers:"
STOPALLEOF
    for ((n=2; n<=NODE_COUNT; n++)); do
        ip_var="NODE${n}_IP"
        echo "echo \"  ssh ${!ip_var} 'sudo systemctl stop llama-rpc'\"" >> /usr/local/bin/stop-everything.sh
    done

    chmod +x /usr/local/bin/stop-everything.sh

    # ── Models directory ────────────────────────────────────
    log "Checking models directory..."
    if [[ -d "$MODELS_DIR" ]]; then
        MODEL_COUNT=$(find "$MODELS_DIR" -name "*.gguf" 2>/dev/null | wc -l)
        log "Models: $MODELS_DIR ($MODEL_COUNT GGUF files)"
    else
        warn "Models directory not found: $MODELS_DIR"
        warn "Install LM Studio or create it manually."
    fi

    # ── Permissions ─────────────────────────────────────────
    log "Setting permissions..."
    MODEL_CACHE_DIR="$ACTUAL_HOME/.cache/huggingface"
    mkdir -p "$MODEL_CACHE_DIR"
    chown -R "$ACTUAL_USER:$ACTUAL_USER" "$MODEL_CACHE_DIR"
    chown "$ACTUAL_USER:$ACTUAL_USER" "$ACTUAL_HOME"
    chown -R "$ACTUAL_USER:$ACTUAL_USER" "$LLAMA_CPP_DIR"

    # ── Summary ─────────────────────────────────────────────
    log "${GREEN}================================================${NC}"
    log "${GREEN}  llama.cpp Setup Complete — Node 1 (Head)${NC}"
    log "${GREEN}================================================${NC}"
    echo ""
    log "Configuration:"
    log "  RDMA devices: ${ACTIVE_RDMA_DEVICES[*]}"
    log "  RDMA interface: $RDMA_NET_IFACE"
    log "  Node IP: $NODE1_IP"
    log "  Workers: $WORKER_COUNT ($WORKER_IPS_STR)"
    log "  GPU(s): $GPU_COUNT x $GPU_NAME"
    log "  CUDA: $CUDA_VERSION"
    log "  llama.cpp: $LLAMA_COMMIT (at $LLAMA_CPP_DIR)"
    log "  Models: $MODELS_DIR"
    echo ""
    log "Binaries:"
    log "  llama-server — HTTP API (OpenAI-compatible)"
    log "  llama-cli    — CLI inference"
    log "  rpc-server   — RPC worker"
    echo ""
    log "Launch commands:"
    log "  Multi-node:  llama-cluster-start.sh <model.gguf>"
    log "  Single:      llama-local-start.sh <model.gguf>"
    log "  Interactive: start-everything.sh"
    echo ""
    log "API: http://$NODE1_IP:$SERVER_PORT/v1"
    log "Web UI: http://$NODE1_IP:$SERVER_PORT"
    echo ""
    log "Management:"
    log "  cluster-status.sh  — Check health"
    log "  cluster-stop.sh    — Stop server"
    log "  stop-everything.sh — Stop all"
    echo ""
    log "${CYAN}Next step on Node 1:${NC}"
    log "  sudo ./setup-models.sh --node 1"
    echo ""
    ;;

# ═════════════════════════════════════
# NODE 2+ — Worker
# ═════════════════════════════════════
*)
    log "Setting up Node $NODE_NUM (Worker) RPC service..."

    # Resolve which Node 1 IP we can actually reach (asymmetric topologies)
    find_reachable_node1_ip

    # ── RPC worker systemd service ──────────────────────────
    cat > /etc/systemd/system/llama-rpc.service << EOF
[Unit]
Description=llama.cpp RPC Worker for Multi-Node Inference
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment="CUDA_VISIBLE_DEVICES=0"
ExecStart=/usr/local/bin/rpc-server --host ${NODE_IP} --port ${RPC_PORT}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable llama-rpc.service
    log "RPC worker service created and enabled (auto-starts on boot)"

    log "Starting RPC worker..."
    systemctl start llama-rpc.service
    sleep 2

    if systemctl is-active llama-rpc.service &>/dev/null; then
        log "RPC worker running on ${NODE_IP}:${RPC_PORT}"
    else
        warn "RPC worker failed to start. Check: journalctl -u llama-rpc -n 20"
    fi

    # ── Status script (worker perspective) ──────────────────
    cat > /usr/local/bin/cluster-status.sh << STATUSEOF
#!/bin/bash
# NODE1_IP here is the IP that's actually reachable from this worker —
# may be Node 1's secondary address for asymmetric (star) RDMA topologies.
NODE1_IP="$NODE1_REACHABLE_IP"
NODE_IP="$NODE_IP"
RPC_PORT="$RPC_PORT"

echo "=== RPC Worker Service (Node $NODE_NUM) ==="
if systemctl is-active llama-rpc.service &>/dev/null; then
    echo "running"
    PID=\$(pgrep -x rpc-server 2>/dev/null)
    [ -n "\$PID" ] && echo "  PID: \$PID"
else
    echo "not running"
    echo "  Start: sudo systemctl start llama-rpc"
fi
echo ""

echo "=== RPC Port ==="
if ss -tlnp | grep -q ":\$RPC_PORT "; then
    echo "listening on \$NODE_IP:\$RPC_PORT"
else
    echo "NOT listening on port \$RPC_PORT"
fi
echo ""

echo "=== GPU Status ==="
nvidia-smi --query-gpu=name,memory.used,memory.total,utilization.gpu --format=csv,noheader 2>/dev/null || echo "nvidia-smi not available"
echo ""

echo "=== RDMA Link ==="
ibdev2netdev 2>/dev/null || echo "ibdev2netdev not available"
echo ""

echo "=== Connectivity to Head (Node 1) ==="
ping -c 1 -W 2 \$NODE1_IP > /dev/null 2>&1 && echo "Node 1 reachable" || echo "Node 1 NOT reachable"
echo ""
STATUSEOF

    chmod +x /usr/local/bin/cluster-status.sh

    # ── Stop script ─────────────────────────────────────────
    cat > /usr/local/bin/cluster-stop.sh << 'STOPEOF'
#!/bin/bash
echo "Stopping RPC worker..."
sudo systemctl stop llama-rpc.service 2>/dev/null
echo "Done."
STOPEOF

    chmod +x /usr/local/bin/cluster-stop.sh

    # ── Permissions ─────────────────────────────────────────
    log "Setting permissions..."
    MODEL_CACHE_DIR="$ACTUAL_HOME/.cache/huggingface"
    mkdir -p "$MODEL_CACHE_DIR"
    chown -R "$ACTUAL_USER:$ACTUAL_USER" "$MODEL_CACHE_DIR"
    chown "$ACTUAL_USER:$ACTUAL_USER" "$ACTUAL_HOME"
    chown -R "$ACTUAL_USER:$ACTUAL_USER" "$LLAMA_CPP_DIR"

    # ── Summary ─────────────────────────────────────────────
    log "${GREEN}================================================${NC}"
    log "${GREEN}  llama.cpp Setup Complete — Node $NODE_NUM (Worker)${NC}"
    log "${GREEN}================================================${NC}"
    echo ""
    log "Configuration:"
    log "  RDMA devices: ${ACTIVE_RDMA_DEVICES[*]}"
    log "  RDMA interface: $RDMA_NET_IFACE"
    log "  Node IP: $NODE_IP"
    log "  Head node: $NODE1_REACHABLE_IP"
    log "  GPU(s): $GPU_COUNT x $GPU_NAME"
    log "  CUDA: $CUDA_VERSION"
    log "  llama.cpp: $LLAMA_COMMIT (at $LLAMA_CPP_DIR)"
    echo ""
    log "Services (auto-start on boot):"
    log "  llama-rpc.service — RPC worker on ${NODE_IP}:${RPC_PORT}"
    log "  rdma-qos.service  — RDMA QoS settings"
    echo ""
    log "Management:"
    log "  cluster-status.sh — Check RPC worker health"
    log "  cluster-stop.sh   — Stop RPC worker"
    log "  systemctl status llama-rpc"
    log "  journalctl -u llama-rpc -f"
    echo ""
    log "${CYAN}Next step on Node $NODE_NUM:${NC}"
    log "  sudo ./setup-models.sh --node $NODE_NUM"
    echo ""
    ;;
esac
