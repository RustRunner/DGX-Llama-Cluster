#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# DGX Spark Llama Cluster — Reset / Clean Slate
# Removes all installed configs, services, and binaries
# so you can re-run setup scripts from scratch.
# Usage: sudo ./reset.sh
# ─────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
load_config

require_root
detect_user

log "${BOLD}DGX Spark Llama Cluster — Reset${NC}"
echo ""
warn "This will remove ALL cluster components from this node:"
echo ""
echo "    - Systemd services (llama-rpc, rdma-qos)"
echo "    - Netplan RDMA config (60-rdma-connectx7.yaml)"
echo "    - Sysctl tuning (99-rdma-tuning.conf)"
echo "    - Modprobe mlx5 config"
echo "    - Installed scripts in /usr/local/bin/"
echo "    - NFS exports and mounts"
echo "    - llama.cpp build ($LLAMA_CPP_DIR)"
echo "    - Desktop launcher"
echo ""

read -p "Continue? (y/n): " -n 1 -r
echo
[[ $REPLY =~ ^[Yy]$ ]] || { log "Aborted."; exit 0; }

# ── Stop running processes ──────────────────────────────────
log "Stopping running processes..."
pkill -x llama-server 2>/dev/null && log "  Stopped llama-server" || true
pkill -x rpc-server 2>/dev/null   && log "  Stopped rpc-server"   || true

# ── Stop and disable services ───────────────────────────────
log "Removing systemd services..."
for svc in llama-rpc rdma-qos; do
    if systemctl is-active "$svc" &>/dev/null; then
        systemctl stop "$svc" 2>/dev/null || true
        log "  Stopped $svc"
    fi
    if systemctl is-enabled "$svc" &>/dev/null; then
        systemctl disable "$svc" 2>/dev/null || true
        log "  Disabled $svc"
    fi
    rm -f "/etc/systemd/system/$svc.service"
done
systemctl daemon-reload

# ── Remove netplan RDMA config ──────────────────────────────
if [[ -f /etc/netplan/60-rdma-connectx7.yaml ]]; then
    rm -f /etc/netplan/60-rdma-connectx7.yaml
    log "Removed RDMA netplan config"
    netplan apply 2>/dev/null || true
fi

# ── Remove sysctl tuning ────────────────────────────────────
if [[ -f /etc/sysctl.d/99-rdma-tuning.conf ]]; then
    rm -f /etc/sysctl.d/99-rdma-tuning.conf
    sysctl --system &>/dev/null || true
    log "Removed RDMA sysctl tuning"
fi

# ── Remove modprobe config ──────────────────────────────────
if [[ -f /etc/modprobe.d/mlx5.conf ]]; then
    rm -f /etc/modprobe.d/mlx5.conf
    log "Removed mlx5 modprobe config"
fi

# ── Remove installed scripts ────────────────────────────────
log "Removing scripts from /usr/local/bin/..."
SCRIPTS=(
    llama-server llama-cli rpc-server
    llama-cluster-start.sh llama-local-start.sh
    start-everything.sh stop-everything.sh
    cluster-status.sh cluster-stop.sh
    verify-rdma.sh verify_rdma.sh
    rdma-test-server.sh rdma-test-client.sh
    rdma_server_test.sh rdma_client_test.sh
    configure-rdma-qos.sh configure_rdma_qos.sh
)
for script in "${SCRIPTS[@]}"; do
    rm -f "/usr/local/bin/$script"
done
log "  Done"

# ── Remove NFS configuration ────────────────────────────────
log "Cleaning NFS configuration..."

if mountpoint -q "$MODELS_DIR" 2>/dev/null; then
    umount "$MODELS_DIR" 2>/dev/null || umount -l "$MODELS_DIR" 2>/dev/null || true
    log "  Unmounted $MODELS_DIR"
fi

if grep -q '\.lmstudio/models' /etc/fstab 2>/dev/null; then
    sed -i '/\.lmstudio\/models/d' /etc/fstab
    log "  Removed fstab NFS entry"
fi

if grep -q '\.lmstudio/models' /etc/exports 2>/dev/null; then
    sed -i '/\.lmstudio\/models/d' /etc/exports
    exportfs -ra 2>/dev/null || true
    log "  Removed NFS export"
fi

# ── Remove llama.cpp build ──────────────────────────────────
if [[ -d "$LLAMA_CPP_DIR" ]]; then
    echo ""
    read -p "Remove llama.cpp build at $LLAMA_CPP_DIR? (y/n): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        rm -rf "$LLAMA_CPP_DIR"
        log "Removed $LLAMA_CPP_DIR"
    else
        log "Kept $LLAMA_CPP_DIR"
    fi
fi

# ── Remove desktop launcher ────────────────────────────────
if [[ -f "$SCRIPT_DIR/install-launcher.sh" ]]; then
    su - "$ACTUAL_USER" -c "bash $SCRIPT_DIR/install-launcher.sh --remove" 2>/dev/null || true
    log "Removed desktop launcher"
fi

# ── Done ────────────────────────────────────────────────────
echo ""
log "${GREEN}========================================${NC}"
log "${GREEN}  Reset complete!${NC}"
log "${GREEN}========================================${NC}"
echo ""
log "This node is clean. To set up again:"
log "  1. sudo ./setup-rdma.sh --node <1|2>"
log "  2. Reboot"
log "  3. sudo ./setup-llama.sh --node <1|2>"
log "  4. sudo ./setup-models.sh --node <1|2>"
echo ""
warn "A reboot is recommended to fully clear RDMA/network state."
echo ""
