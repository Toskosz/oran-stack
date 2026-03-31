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
    echo "Usage: sudo ./scripts/setup-host-network.sh"
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
    if iptables -t nat -C POSTROUTING -s "$subnet" ! -o "$iface" -j MASQUERADE 2>/dev/null; then
        echo "[OK] IPv4 NAT rule already exists for $subnet"
    elif iptables -t nat -A POSTROUTING -s "$subnet" ! -o "$iface" -j MASQUERADE 2>/dev/null; then
        echo "[OK] IPv4 NAT rule added for $subnet"
    else
        echo "[WARN] Failed to add IPv4 NAT rule for $subnet"
    fi
done

# IPv6 NAT for each TUN interface
declare -a ipv6_subnets=("2001:db8:cafe::/48:ogstun" "2001:db8:babe::/48:ogstun2" "2001:db8:face::/48:ogstun3")
for entry in "${ipv6_subnets[@]}"; do
    IFS=':' read -r subnet iface <<< "$entry"
    echo "[INFO] Adding IPv6 NAT for $subnet ($iface)..."
    if ip6tables -t nat -C POSTROUTING -s "$subnet" ! -o "$iface" -j MASQUERADE 2>/dev/null; then
        echo "[OK] IPv6 NAT rule already exists for $subnet"
    elif ip6tables -t nat -A POSTROUTING -s "$subnet" ! -o "$iface" -j MASQUERADE 2>/dev/null; then
        echo "[OK] IPv6 NAT rule added for $subnet"
    else
        echo "[WARN] Failed to add IPv6 NAT rule for $subnet"
    fi
done

echo "[OK] NAT rules configured"

echo ""
echo "[INFO] Configuring security rules..."

# Accept traffic on TUN interfaces
declare -a ifaces=("ogstun" "ogstun2" "ogstun3")
for iface in "${ifaces[@]}"; do
    echo "[INFO] Accepting traffic on $iface..."
    if iptables -C INPUT -i "$iface" -j ACCEPT 2>/dev/null; then
        echo "[OK] Firewall rule already exists for $iface"
    elif iptables -I INPUT -i "$iface" -j ACCEPT 2>/dev/null; then
        echo "[OK] Firewall rule added for $iface"
    else
        echo "[WARN] Failed to add firewall rule for $iface"
    fi
done

echo "[OK] Security rules configured"

echo ""
echo "[INFO] Configuring UFW rules for 5G core interfaces..."
if command -v ufw &> /dev/null; then
    # Allow input traffic on each TUN interface (UE-to-core traffic).
    # UFW rules are idempotent – adding a rule that already exists is a no-op.
    declare -a tun_ifaces=("ogstun" "ogstun2" "ogstun3")
    for iface in "${tun_ifaces[@]}"; do
        if ufw allow in on "$iface" 2>/dev/null; then
            echo "[OK] UFW allow-in rule set for $iface"
        else
            echo "[WARN] Failed to set UFW allow-in rule for $iface"
        fi
    done

    # Enable packet forwarding in UFW by setting DEFAULT_FORWARD_POLICY=ACCEPT
    # in /etc/default/ufw if it is not already set, so that MASQUERADE rules
    # are effective while UFW remains enabled.
    UFW_DEFAULT=/etc/default/ufw
    if [ -f "$UFW_DEFAULT" ]; then
        if grep -q '^DEFAULT_FORWARD_POLICY="DROP"' "$UFW_DEFAULT"; then
            sed -i 's/^DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/' "$UFW_DEFAULT"
            echo "[OK] UFW DEFAULT_FORWARD_POLICY set to ACCEPT in $UFW_DEFAULT"
            echo "[INFO] Reloading UFW to apply forwarding policy change..."
            ufw reload 2>/dev/null && echo "[OK] UFW reloaded" || echo "[WARN] UFW reload failed"
        else
            echo "[OK] UFW DEFAULT_FORWARD_POLICY already allows forwarding"
        fi
    else
        echo "[WARN] $UFW_DEFAULT not found; verify UFW forwarding policy manually"
    fi

    echo "[OK] UFW configured – firewall remains enabled"
    echo ""
    echo "Required UFW rules summary:"
    echo "  ufw allow in on ogstun"
    echo "  ufw allow in on ogstun2"
    echo "  ufw allow in on ogstun3"
    echo "  DEFAULT_FORWARD_POLICY=ACCEPT  (in /etc/default/ufw)"
else
    echo "[INFO] UFW not installed; relying solely on iptables rules above"
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
