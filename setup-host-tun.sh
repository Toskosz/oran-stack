#!/bin/bash
# Setup script for 5G core with Host TUN interfaces
# This creates the TUN interfaces on the host that will be shared with containers

set -e

echo "=========================================="
echo "5G Core Host Setup"
echo "=========================================="
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    echo "[ERROR] This script must be run as root"
    echo "Usage: sudo ./setup-host-tun.sh"
    exit 1
fi

echo "[INFO] Creating TUN interfaces on host..."

# Create TUN interfaces if they don't exist
for interface in ogstun ogstun2 ogstun3; do
    if ip link show "$interface" > /dev/null 2>&1; then
        echo "[OK] $interface already exists"
    else
        echo "[INFO] Creating $interface..."
        ip tuntap add name "$interface" mode tun
        ip link set "$interface" up
        echo "[OK] Created $interface"
    fi
done

echo ""
echo "[INFO] Configuring IP addresses for TUN interfaces..."

# Configure addresses (these will be inherited/accessible from containers)
ip addr add 10.45.0.1/16 dev ogstun 2>/dev/null || echo "[INFO] ogstun IP already configured"
ip addr add 2001:db8:cafe::1/48 dev ogstun 2>/dev/null || echo "[INFO] ogstun IPv6 already configured"

ip addr add 10.46.0.1/16 dev ogstun2 2>/dev/null || echo "[INFO] ogstun2 IP already configured"
ip addr add 2001:db8:babe::1/48 dev ogstun2 2>/dev/null || echo "[INFO] ogstun2 IPv6 already configured"

ip addr add 10.47.0.1/16 dev ogstun3 2>/dev/null || echo "[INFO] ogstun3 IP already configured"
ip addr add 2001:db8:face::1/48 dev ogstun3 2>/dev/null || echo "[INFO] ogstun3 IPv6 already configured"

echo ""
echo "[INFO] Verifying TUN interfaces..."
echo ""
ip tuntap list
echo ""
echo "[OK] Host TUN setup complete!"
echo ""
echo "You can now start the docker-compose stack:"
echo "  docker-compose up -d"
echo ""
