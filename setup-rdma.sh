#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# DGX Spark Llama Cluster — ConnectX-7 RDMA Setup
# Configures networking, MLNX OFED, RoCE, PFC/QoS, tuning
# Usage: sudo ./setup-rdma.sh --node <1|2>
# ─────────────────────────────────────────────────────────────

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
load_config

require_root
parse_node_arg "$@"

log "Starting ConnectX-7 RDMA setup for Node $NODE_NUM ($NODE_ROLE)"

#######################################
# Step 1: Detect Network Interfaces
#######################################

detect_mlx5_interfaces

#######################################
# Step 2: Configure Netplan
#######################################

log "Configuring netplan for dual-port RDMA..."

NETPLAN_DIR="/etc/netplan"
BACKUP_DIR="$NETPLAN_DIR/backup_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BACKUP_DIR"

if ls "$NETPLAN_DIR"/*.yaml 1>/dev/null 2>&1; then
    log "Backing up existing netplan to $BACKUP_DIR"
    cp "$NETPLAN_DIR"/*.yaml "$BACKUP_DIR/" || true
fi

NETPLAN_FILE="$NETPLAN_DIR/60-rdma-connectx7.yaml"

cat > "$NETPLAN_FILE" << EOF
network:
  version: 2
  renderer: NetworkManager
  ethernets:
    $IFACE1:
      addresses: [$NODE_IP/24]
      mtu: $MTU
      optional: true
    $IFACE2:
      addresses: [$NODE_IP2/24]
      mtu: $MTU
      optional: true
EOF

chmod 600 "$NETPLAN_FILE"
log "Created $NETPLAN_FILE"
log "Existing netplan files preserved (netplan merges all yaml files)"

log "Applying netplan..."
netplan apply || warn "Netplan apply had warnings, continuing..."
sleep 3

log "Verifying interfaces..."
ip addr show "$IFACE1" | grep "$NODE_IP" || warn "$IFACE1 may not have $NODE_IP"
ip addr show "$IFACE2" | grep "$NODE_IP2" || warn "$IFACE2 may not have $NODE_IP2"

#######################################
# Step 3: Install MLNX OFED Drivers
#######################################

log "Checking for MLNX OFED drivers..."

if ! command -v ibv_devinfo &>/dev/null; then
    log "MLNX OFED not found. Installing..."

    apt-get update
    apt-get install -y wget tar build-essential dkms python3 perl lsof

    UBUNTU_VERSION=$(lsb_release -rs | tr -d '.')
    ARCH=$(uname -m)
    OFED_FILE="MLNX_OFED_LINUX-${OFED_VERSION}-ubuntu${UBUNTU_VERSION}-${ARCH}.tgz"

    cd /tmp
    if [[ ! -f "$OFED_FILE" ]]; then
        warn "Expected: $OFED_FILE"
        warn "Download from: https://network.nvidia.com/products/infiniband-drivers/linux/mlnx_ofed/"
        warn "Looking for any pre-downloaded OFED file in /tmp..."

        OFED_FILE=$(ls MLNX_OFED_LINUX-*.tgz 2>/dev/null | head -n1 || echo "")
        [[ -z "$OFED_FILE" ]] && error "MLNX OFED not found in /tmp. Download it manually."
    fi

    log "Installing from $OFED_FILE..."
    tar -xzf "$OFED_FILE"

    OFED_DIR=$(ls -d MLNX_OFED_LINUX-*/ 2>/dev/null | head -n1)
    [[ -z "$OFED_DIR" ]] && error "Could not find extracted OFED directory"
    cd "$OFED_DIR"

    ./mlnxofedinstall --add-kernel-support --without-fw-update --force

    log "Restarting OFED drivers..."
    /etc/init.d/openibd restart
else
    log "MLNX OFED already installed"
fi

log "Installing perftest utilities..."
apt-get install -y perftest || warn "perftest installation had issues"

#######################################
# Step 4: Configure ConnectX-7 Firmware
#######################################

log "Configuring ConnectX-7 firmware..."

FIRMWARE_CHANGED=false

if command -v mst &>/dev/null && command -v mlxconfig &>/dev/null; then
    mst start
    MST_DEVICE=$(mst status -v | grep -oP '/dev/mst/mt\d+_pciconf\d+' | head -n1)

    if [[ -z "$MST_DEVICE" ]]; then
        warn "Could not find MST device. Skipping firmware configuration."
    else
        log "MST device: $MST_DEVICE"

        log "Current configuration:"
        mlxconfig -d "$MST_DEVICE" q | grep -E "LINK_TYPE|ROCE_EN" || true

        CURRENT_LINK=$(mlxconfig -d "$MST_DEVICE" q 2>/dev/null | grep -c "LINK_TYPE_P.*ETH(2)" || true)
        CURRENT_ROCE=$(mlxconfig -d "$MST_DEVICE" q 2>/dev/null | grep -c "ROCE_EN.*True(1)" || true)

        if [[ "$CURRENT_LINK" -ge 2 ]] && [[ "$CURRENT_ROCE" -ge 1 ]]; then
            log "Firmware already correct (Ethernet mode, RoCE enabled)"
        else
            log "Setting Ethernet mode with RoCE..."
            mlxconfig -d "$MST_DEVICE" set LINK_TYPE_P1=2 LINK_TYPE_P2=2 -y
            mlxconfig -d "$MST_DEVICE" set ROCE_EN=1 -y
            FIRMWARE_CHANGED=true

            log "Firmware configured. New settings:"
            mlxconfig -d "$MST_DEVICE" q | grep -E "LINK_TYPE|ROCE_EN" || true
        fi
    fi
else
    warn "MFT tools not installed. Checking RoCE via ibv_devinfo..."
    ROCE_ACTIVE=$(ibv_devinfo 2>/dev/null | grep -c "link_layer:.*Ethernet" || true)
    if [[ "$ROCE_ACTIVE" -ge 1 ]]; then
        log "RoCE verified active ($ROCE_ACTIVE ports)"
    else
        warn "Could not verify RoCE. Install MFT: apt-get install -y mft"
    fi
fi

#######################################
# Step 5: RDMA Kernel Parameters
#######################################

log "Configuring RDMA parameters..."

cat > /etc/modprobe.d/mlx5.conf << EOF
options mlx5_core roce_enable=1
EOF

log "mlx5 module config written — takes effect after reboot"

#######################################
# Step 6: PFC and QoS
#######################################

log "Configuring Priority Flow Control and QoS..."

cat > /usr/local/bin/configure-rdma-qos.sh << 'QOSEOF'
#!/bin/bash
# Applied by rdma-qos.service on boot
IFACES=$(ls -d /sys/class/net/*/device/driver 2>/dev/null | while read -r d; do
    readlink -f "$d" | grep -q mlx5 && basename "$(dirname "$(dirname "$d")")"
done | sort)

for IFACE in $IFACES; do
    if command -v mlnx_qos &>/dev/null; then
        mlnx_qos -i "$IFACE" --pfc 0,0,0,1,0,0,0,0 || true
        mlnx_qos -i "$IFACE" --trust dscp || true
    fi
done
QOSEOF

chmod +x /usr/local/bin/configure-rdma-qos.sh

cat > /etc/systemd/system/rdma-qos.service << EOF
[Unit]
Description=RDMA PFC/QoS Configuration
After=network-online.target openibd.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/configure-rdma-qos.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable rdma-qos.service

if command -v mlnx_qos &>/dev/null; then
    mlnx_qos -i "$IFACE1" --pfc 0,0,0,1,0,0,0,0 || warn "PFC config failed for $IFACE1"
    mlnx_qos -i "$IFACE2" --pfc 0,0,0,1,0,0,0,0 || warn "PFC config failed for $IFACE2"
    mlnx_qos -i "$IFACE1" --trust dscp || warn "Trust mode failed for $IFACE1"
    mlnx_qos -i "$IFACE2" --trust dscp || warn "Trust mode failed for $IFACE2"
else
    warn "mlnx_qos not found, PFC will be configured after reboot via rdma-qos.service"
fi

#######################################
# Step 7: System Network Tuning
#######################################

log "Applying network performance tuning..."

cp /etc/sysctl.conf "/etc/sysctl.conf.backup_$(date +%Y%m%d_%H%M%S)"

cat > /etc/sysctl.d/99-rdma-tuning.conf << EOF
# RDMA Performance Tuning — DGX Spark Llama Cluster
net.ipv4.tcp_rmem = 4096 87380 134217728
net.ipv4.tcp_wmem = 4096 65536 134217728
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.core.rmem_default = 134217728
net.core.wmem_default = 134217728
net.core.optmem_max = 134217728
net.core.netdev_max_backlog = 250000
EOF

if modprobe htcp 2>/dev/null || grep -q htcp /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
    echo "net.ipv4.tcp_congestion_control = htcp" >> /etc/sysctl.d/99-rdma-tuning.conf
    log "Using htcp congestion control"
else
    warn "htcp not available, using system default"
fi

sysctl --system

#######################################
# Step 8: Verification & Test Scripts
#######################################

log "Creating verification scripts..."

cat > /usr/local/bin/verify-rdma.sh << 'VERIFYEOF'
#!/bin/bash
echo "=== RDMA Verification ==="
echo ""

echo "1. RDMA Devices:"
ibv_devices 2>/dev/null || echo "  ibv_devices not found"
echo ""

echo "2. Device Info:"
ibv_devinfo 2>/dev/null | grep -E "hca_id|port:|state:|active_width|active_speed" || echo "  ibv_devinfo not found"
echo ""

echo "3. Link Status:"
ibstat 2>/dev/null | grep -E "CA|Port|State|Rate" || echo "  ibstat not found"
echo ""

echo "4. Network Interfaces (mlx5):"
for d in /sys/class/net/*/device/driver; do
    readlink -f "$d" 2>/dev/null | grep -q mlx5 && {
        IFACE=$(basename "$(dirname "$(dirname "$d")")")
        echo "  $IFACE: $(ip -4 addr show "$IFACE" 2>/dev/null | grep inet | awk '{print $2}')"
    }
done
echo ""

echo "5. RoCE GIDs:"
show_gids 2>/dev/null || echo "  show_gids not found"
echo ""

echo "6. Card Information:"
mst start 2>/dev/null
MST_DEVICE=$(mst status -v 2>/dev/null | grep -oP '/dev/mst/mt\d+_pciconf\d+' | head -n1)
if [ -n "$MST_DEVICE" ]; then
    mlxconfig -d "$MST_DEVICE" q | grep -E "LINK_TYPE|ROCE_EN"
else
    echo "  MST device not found"
fi
echo ""

echo "7. RDMA Device to Netdev Mapping:"
ibdev2netdev 2>/dev/null || echo "  ibdev2netdev not found"
echo ""

echo "8. llama.cpp RDMA Support:"
for bin in /usr/local/bin/rpc-server /usr/local/bin/llama-server; do
    if [ -x "$bin" ]; then
        if ldd "$bin" 2>/dev/null | grep -q ibverbs; then
            echo "  $(basename "$bin"): RDMA enabled (libibverbs linked)"
        else
            echo "  $(basename "$bin"): TCP only (libibverbs not linked — rebuild after installing libibverbs-dev)"
        fi
    else
        echo "  $(basename "$bin"): not installed yet — run setup-llama.sh"
    fi
done
echo ""

echo "=== Verification Complete ==="
VERIFYEOF

chmod +x /usr/local/bin/verify-rdma.sh

# RDMA bandwidth test — server side (same on both nodes)
cat > /usr/local/bin/rdma-test-server.sh << 'SRVEOF'
#!/bin/bash
# Start RDMA bandwidth test server
# Run rdma-test-client.sh on the peer node to connect

DEVICES=($(ls /sys/class/infiniband/ 2>/dev/null | sort))
[[ ${#DEVICES[@]} -eq 0 ]] && { echo "ERROR: No RDMA devices found"; exit 1; }

echo "Starting RDMA bandwidth test server..."
echo "Detected: ${DEVICES[*]}"

ROCEV2_GID_IDX=3
if command -v show_gids &>/dev/null; then
    DETECTED=$(show_gids 2>/dev/null | grep "RoCE v2" | head -n1 | awk '{print $3}')
    [[ -n "$DETECTED" ]] && ROCEV2_GID_IDX=$DETECTED
fi
echo "GID index: $ROCEV2_GID_IDX"
echo ""

if [[ ${#DEVICES[@]} -ge 2 ]]; then
    echo "Device 1 (${DEVICES[0]} port 1) on TCP port 18515:"
    ib_write_bw -d "${DEVICES[0]}" -i 1 --gid-index "$ROCEV2_GID_IDX" -p 18515 &
    PID1=$!
    sleep 2
    echo "Device 2 (${DEVICES[1]} port 1) on TCP port 18516:"
    ib_write_bw -d "${DEVICES[1]}" -i 1 --gid-index "$ROCEV2_GID_IDX" -p 18516 &
    PID2=$!
else
    echo "Single device: ${DEVICES[0]} port 1 on TCP port 18515:"
    ib_write_bw -d "${DEVICES[0]}" -i 1 --gid-index "$ROCEV2_GID_IDX" -p 18515 &
    PID1=$!
    sleep 2
    echo "Single device: ${DEVICES[0]} port 2 on TCP port 18516:"
    ib_write_bw -d "${DEVICES[0]}" -i 2 --gid-index "$ROCEV2_GID_IDX" -p 18516 &
    PID2=$!
fi

echo ""
echo "Server running on ports 18515, 18516. Press Ctrl+C to stop."
echo "Peer should connect to $NODE_IP (18515) and $NODE_IP2 (18516)"
wait $PID1 $PID2 2>/dev/null
SRVEOF

chmod +x /usr/local/bin/rdma-test-server.sh

# RDMA bandwidth test — client side (peer IPs baked in)
cat > /usr/local/bin/rdma-test-client.sh << CLIENTEOF
#!/bin/bash
# Connect to RDMA bandwidth test server on the peer node

PEER_IP1="$PEER_IP"
PEER_IP2="$PEER_IP2"

DEVICES=(\$(ls /sys/class/infiniband/ 2>/dev/null | sort))
[[ \${#DEVICES[@]} -eq 0 ]] && { echo "ERROR: No RDMA devices found"; exit 1; }

echo "RDMA bandwidth test client"
echo "Detected: \${DEVICES[*]}"
echo "Connecting to \$PEER_IP1 and \$PEER_IP2"
echo ""

echo "Testing connectivity..."
ping -c 2 \$PEER_IP1 || echo "Warning: Cannot ping \$PEER_IP1"
ping -c 2 \$PEER_IP2 || echo "Warning: Cannot ping \$PEER_IP2"

ROCEV2_GID_IDX=3
if command -v show_gids &>/dev/null; then
    DETECTED=\$(show_gids 2>/dev/null | grep "RoCE v2" | head -n1 | awk '{print \$3}')
    [[ -n "\$DETECTED" ]] && ROCEV2_GID_IDX=\$DETECTED
fi
echo "GID index: \$ROCEV2_GID_IDX"
echo ""

echo "Make sure the peer is running: sudo rdma-test-server.sh"
read -p "Press Enter when server is ready..."
echo ""

if [[ \${#DEVICES[@]} -ge 2 ]]; then
    echo "Testing Device 1 (\${DEVICES[0]} port 1) -> \$PEER_IP1:"
    ib_write_bw -d "\${DEVICES[0]}" -i 1 --gid-index "\$ROCEV2_GID_IDX" -p 18515 "\$PEER_IP1"
    echo ""
    sleep 3
    echo "Testing Device 2 (\${DEVICES[1]} port 1) -> \$PEER_IP2:"
    ib_write_bw -d "\${DEVICES[1]}" -i 1 --gid-index "\$ROCEV2_GID_IDX" -p 18516 "\$PEER_IP2"
else
    echo "Testing Port 1 (\${DEVICES[0]} port 1) -> \$PEER_IP1:"
    ib_write_bw -d "\${DEVICES[0]}" -i 1 --gid-index "\$ROCEV2_GID_IDX" -p 18515 "\$PEER_IP1"
    echo ""
    sleep 3
    echo "Testing Port 2 (\${DEVICES[0]} port 2) -> \$PEER_IP2:"
    ib_write_bw -d "\${DEVICES[0]}" -i 2 --gid-index "\$ROCEV2_GID_IDX" -p 18516 "\$PEER_IP2"
fi

echo ""
echo "Test complete!"
CLIENTEOF

chmod +x /usr/local/bin/rdma-test-client.sh

#######################################
# Done
#######################################

log "${GREEN}========================================${NC}"
log "${GREEN}  RDMA Setup Complete — Node $NODE_NUM ($NODE_ROLE)${NC}"
log "${GREEN}========================================${NC}"
echo ""
if [[ "$FIRMWARE_CHANGED" = true ]]; then
    warn "IMPORTANT: Reboot REQUIRED to apply firmware changes."
else
    warn "Reboot recommended to ensure all settings are active."
fi
echo ""
log "After reboot, verify with:"
log "  sudo verify-rdma.sh"
echo ""
log "${CYAN}Next step on Node $NODE_NUM (after reboot):${NC}"
log "  sudo ./setup-llama.sh --node $NODE_NUM"
echo ""
log "To test RDMA bandwidth between nodes (optional):"
log "  On one node:  sudo rdma-test-server.sh"
log "  On the other: sudo rdma-test-client.sh"
echo ""
log "Netplan backup: $BACKUP_DIR"
log "QoS service: rdma-qos.service (enabled, persistent)"
echo ""

read -p "Reboot now? (y/n): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    log "Rebooting in 5 seconds... (Ctrl+C to cancel)"
    sleep 5
    reboot
else
    warn "Please reboot manually: sudo reboot"
fi
