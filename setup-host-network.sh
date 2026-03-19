#!/bin/bash
# Setup script for 5G core data plane networking
# Enables UEs to reach the internet through the core network
# This configures IP forwarding, NAT rules, and security rules on the host

set -e

echo "=========================================="
echo "5G Core Data Plane Network Setup"
echo "=========================================="
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    echo "[ERROR] This script must be run as root"
    echo "Usage: sudo ./setup-host-network.sh"
    exit 1
fi

echo "[INFO] Enabling IP forwarding..."

# IPv4 forwarding
if sysctl -w net.ipv4.ip_forward=1 > /dev/null 2>&1; then
    echo "[OK] IPv4 forwarding enabled"
else
    echo "[WARN] Failed to enable IPv4 forwarding"
fi

# IPv6 forwarding
if sysctl -w net.ipv6.conf.all.forwarding=1 > /dev/null 2>&1; then
    echo "[OK] IPv6 forwarding enabled"
else
    echo "[WARN] Failed to enable IPv6 forwarding"
fi

echo ""
echo "[INFO] Configuring NAT rules..."

# IPv4 NAT for each TUN interface
declare -a ipv4_subnets=("10.45.0.0/16:ogstun" "10.46.0.0/16:ogstun2" "10.47.0.0/16:ogstun3")
for entry in "${ipv4_subnets[@]}"; do
    IFS=':' read -r subnet iface <<< "$entry"
    echo "[INFO] Adding IPv4 NAT for $subnet ($iface)..."
    if iptables -t nat -A POSTROUTING -s "$subnet" ! -o "$iface" -j MASQUERADE 2>/dev/null; then
        echo "[OK] IPv4 NAT rule added for $subnet"
    else
        echo "[WARN] IPv4 NAT rule may already exist for $subnet"
    fi
done

# IPv6 NAT for each TUN interface
declare -a ipv6_subnets=("2001:db8:cafe::/48:ogstun" "2001:db8:babe::/48:ogstun2" "2001:db8:face::/48:ogstun3")
for entry in "${ipv6_subnets[@]}"; do
    IFS=':' read -r subnet iface <<< "$entry"
    echo "[INFO] Adding IPv6 NAT for $subnet ($iface)..."
    if ip6tables -t nat -A POSTROUTING -s "$subnet" ! -o "$iface" -j MASQUERADE 2>/dev/null; then
        echo "[OK] IPv6 NAT rule added for $subnet"
    else
        echo "[WARN] IPv6 NAT rule may already exist for $subnet"
    fi
done

echo "[OK] NAT rules configured"

echo ""
echo "[INFO] Configuring security rules..."

# Accept traffic on TUN interfaces
declare -a ifaces=("ogstun" "ogstun2" "ogstun3")
for iface in "${ifaces[@]}"; do
    echo "[INFO] Accepting traffic on $iface..."
    if iptables -I INPUT -i "$iface" -j ACCEPT 2>/dev/null; then
        echo "[OK] Firewall rule added for $iface"
    else
        echo "[WARN] Firewall rule may already exist for $iface"
    fi
done

echo "[OK] Security rules configured"

echo ""
echo "[INFO] Disabling firewall (UFW)..."
if command -v ufw &> /dev/null; then
    if ufw disable 2>/dev/null; then
        echo "[OK] Firewall disabled"
    else
        echo "[WARN] UFW already disabled or error occurred"
    fi
else
    echo "[INFO] UFW not installed"
fi

echo ""
echo "=========================================="
echo "[OK] Data plane network setup complete!"
echo "=========================================="
echo ""
echo "Verification commands:"
echo "  sysctl net.ipv4.ip_forward  (should be 1)"
echo "  iptables -t nat -L -n | grep MASQUERADE"
echo ""
echo "Next steps:"
echo "  1. Start the 5G core: docker-compose up -d"
echo "  2. Verify NF connectivity"
echo "  3. Configure UE and test attachment"
echo ""
