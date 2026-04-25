#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# DGX Spark Llama Cluster — Shared Models Setup
# Node 1: Exports models via NFS (server)
# Node 2+: Mounts models from Node 1 (client)
# Usage: sudo ./setup-models.sh --node <1-N>
# ─────────────────────────────────────────────────────────────

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
load_config

require_root
detect_user
parse_node_arg "$@"

case "$NODE_NUM" in

# ═════════════════════════════════════
# NODE 1 — NFS Server
# ═════════════════════════════════════
1)
    log "Setting up NFS model server on Node 1"

    # Create shared models directory
    log "Creating models directory: $MODELS_DIR"
    mkdir -p "$MODELS_DIR"

    # Install NFS server
    log "Installing NFS server..."
    apt-get install -y nfs-kernel-server

    # Build NFS export line for all worker IPs
    # Remove any existing export for this path, then add fresh
    if grep -q "^$MODELS_DIR " /etc/exports 2>/dev/null; then
        log "Removing old NFS export for $MODELS_DIR"
        sed -i "\|^$MODELS_DIR |d" /etc/exports
    fi

    EXPORT_CLIENTS=""
    for ((n=2; n<=NODE_COUNT; n++)); do
        ip=$(get_node_ip "$n")
        EXPORT_CLIENTS+=" ${ip}(ro,sync,no_subtree_check,no_root_squash)"
    done
    echo "$MODELS_DIR$EXPORT_CLIENTS" >> /etc/exports
    log "NFS export: $MODELS_DIR ->$(get_all_worker_ips)"

    exportfs -ra
    systemctl enable --now nfs-server
    log "NFS server running"

    # Done
    log "${GREEN}================================================${NC}"
    log "${GREEN}  Node 1 Shared Models Setup Complete!${NC}"
    log "${GREEN}================================================${NC}"
    echo ""
    log "Shared directory: $MODELS_DIR"
    log "Exported to $((NODE_COUNT - 1)) worker(s): $(get_all_worker_ips)"
    echo ""
    log "${GREEN}Node 1 setup is complete.${NC}"
    echo ""
    log "${CYAN}Optional:${NC} Install the desktop launcher icon (no sudo):"
    log "  ./install-launcher.sh"
    echo ""
    log "${CYAN}Next:${NC} Copy this repo to each worker node, then on each worker run:"
    log "  sudo ./setup-rdma.sh --node <N>    (reboot)"
    log "  sudo ./setup-llama.sh --node <N>"
    log "  sudo ./setup-models.sh --node <N>"
    echo ""
    log "Then download models (LM Studio downloads go here automatically):"
    log "  cd $MODELS_DIR"
    log "  huggingface-cli download <org>/<model> --include '*Q4_K_M*' --local-dir ."
    echo ""
    log "Once everything is ready, launch a model from Node 1:"
    log "  sudo start-everything.sh"
    log "  (or click the \"DGX Spark Cluster\" desktop icon)"
    echo ""
    ;;

# ═════════════════════════════════════
# NODE 2+ — NFS Client
# ═════════════════════════════════════
*)
    log "Setting up NFS model mount on Node $NODE_NUM"

    # Resolve which Node 1 IP we can actually reach (asymmetric topologies)
    find_reachable_node1_ip

    # Discover Node 1's export
    NODE1_EXPORT=$(showmount -e "$NODE1_REACHABLE_IP" --no-headers 2>/dev/null | awk '{print $1}' | grep '\.lmstudio/models' | head -1)
    if [[ -z "$NODE1_EXPORT" ]]; then
        error "Could not find .lmstudio/models export on $NODE1_REACHABLE_IP. Run setup-models.sh --node 1 on Node 1 first."
    fi
    log "Discovered Node 1 export: $NODE1_EXPORT"

    # Install NFS client
    log "Installing NFS client..."
    apt-get install -y nfs-common

    # Mount
    log "Setting up mount: $NODE1_REACHABLE_IP:$NODE1_EXPORT -> $MODELS_DIR"
    mkdir -p "$MODELS_DIR"

    # Portable mount options so the node can boot away from the cluster:
    #   nofail  — don't block boot if mount fails
    #   bg      — retry in background after first foreground failure
    #   _netdev — wait for network-online before attempting mount
    #   soft    — return EIO instead of hanging forever on a dead server
    NFS_OPTS="ro,nofail,bg,_netdev,soft,timeo=50,retrans=2,nconnect=4"

    # Always rewrite the entry so re-runs apply current options. Match any
    # existing .lmstudio/models line regardless of which IP it points at —
    # this heals stale entries from a prior run that used the wrong subnet.
    if grep -q '\.lmstudio/models' /etc/fstab 2>/dev/null; then
        sed -i '\|\.lmstudio/models|d' /etc/fstab
        log "Updated fstab entry with portable mount options"
    else
        log "Added fstab entry with portable mount options"
    fi
    echo "$NODE1_REACHABLE_IP:$NODE1_EXPORT $MODELS_DIR nfs $NFS_OPTS 0 0" >> /etc/fstab

    # Mount if not already mounted
    if mountpoint -q "$MODELS_DIR" 2>/dev/null; then
        log "$MODELS_DIR is already mounted"
    else
        mount "$MODELS_DIR" || error "Failed to mount. Check Node 1's NFS server."
        log "$MODELS_DIR mounted"
    fi

    # Verify
    if ls "$MODELS_DIR" &>/dev/null; then
        MODEL_COUNT=$(find "$MODELS_DIR" -name "*.gguf" 2>/dev/null | wc -l)
        log "Mount verified — $MODEL_COUNT GGUF model file(s) found"
    else
        warn "Mount exists but cannot list contents"
    fi

    # Done
    log "${GREEN}================================================${NC}"
    log "${GREEN}  Node $NODE_NUM Shared Models Setup Complete!${NC}"
    log "${GREEN}================================================${NC}"
    echo ""
    log "NFS mount: $NODE1_REACHABLE_IP:$NODE1_EXPORT -> $MODELS_DIR (read-only)"
    echo ""
    log "Models from Node 1 are now accessible here."
    log "The RPC worker will serve layers from these models"
    log "when Node 1's llama-server connects."
    echo ""
    log "${GREEN}Node $NODE_NUM setup is complete.${NC}"
    echo ""
    log "${CYAN}Next:${NC} Go back to Node 1 and launch a model:"
    log "  sudo start-everything.sh"
    log "  (or: sudo llama-cluster-start.sh $MODELS_DIR/<org>/<model>/<file>.gguf)"
    echo ""
    ;;
esac
