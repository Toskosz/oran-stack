#!/bin/bash

# Set error handling: log errors but don't exit immediately
set -o pipefail
trap 'echo "[WARN] Command failed at line $LINENO with exit code $?"' ERR

echo "[INFO] Starting Open5GS entrypoint..."

# ============================================================================
# Configuration Setup - Populate YAML files from templates
# ============================================================================

echo "[INFO] Populating configuration files from templates..."

# Ensure output directory exists
mkdir -p /open5gs/install/etc/open5gs

# List of all NF configuration files
declare -a configs=("nrf" "scp" "sepp1" "amf" "smf" "upf" "ausf" "udm" "pcf" "nssf" "bsf" "udr" "mme" "sgwc" "sgwu" "hss" "pcrf")

# Substitute environment variables in each config template
for config in "${configs[@]}"; do
    if [ -f "/open5gs/configs/${config}.yaml" ]; then
        echo "[INFO] Processing ${config}.yaml..."
        if envsubst < "/open5gs/configs/${config}.yaml" > "/open5gs/install/etc/open5gs/${config}.yaml"; then
            echo "[OK] Generated /open5gs/install/etc/open5gs/${config}.yaml"
        else
            echo "[WARN] Failed to process ${config}.yaml"
        fi
    else
        echo "[WARN] Template not found: /open5gs/configs/${config}.yaml"
    fi
done

echo "[OK] Configuration files populated"
echo ""

# ============================================================================
# Network Configuration (with error handling)
# ============================================================================

# Check if TUN interfaces exist on the host
# If running in a container with host TUN access, they should already exist
if ! grep "ogstun" /proc/net/dev > /dev/null 2>&1; then
    echo "[INFO] ogstun interface not found, attempting to create..."
    if ip tuntap add name ogstun mode tun 2>/dev/null; then
        echo "[OK] Created ogstun interface"
    else
        echo "[WARN] Failed to create ogstun interface (may already exist or no CAP_NET_ADMIN)"
    fi
else
    echo "[OK] ogstun interface already exists"
fi

# Configure IPv6 for ogstun
if [ -f /proc/sys/net/ipv6/conf/ogstun/disable_ipv6 ]; then
    if [ "$(sysctl -n net.ipv6.conf.ogstun.disable_ipv6 2>/dev/null || echo '0')" = "1" ]; then
        echo "[INFO] Disabling IPv6 on ogstun..."
        if echo "net.ipv6.conf.ogstun.disable_ipv6=0" > /etc/sysctl.d/30-open5gs.conf 2>/dev/null; then
            sysctl -p /etc/sysctl.d/30-open5gs.conf > /dev/null 2>&1 || echo "[WARN] sysctl apply failed"
            echo "[OK] IPv6 configured for ogstun"
        else
            echo "[WARN] Failed to write sysctl config"
        fi
    fi
else
    echo "[INFO] ogstun IPv6 config not available (likely created on host)"
fi

# Configure IP addresses for TUN interfaces
# These may fail if interfaces are on the host, which is expected
if ip link show ogstun > /dev/null 2>&1; then
    echo "[INFO] Configuring ogstun..."
    ip addr add 10.45.0.1/16 dev ogstun 2>/dev/null && echo "[OK] Added IPv4 to ogstun" || echo "[WARN] Failed to add IPv4 to ogstun"
    ip addr add 2001:db8:cafe::1/48 dev ogstun 2>/dev/null && echo "[OK] Added IPv6 to ogstun" || echo "[WARN] Failed to add IPv6 to ogstun"
    ip link set ogstun up 2>/dev/null && echo "[OK] Brought up ogstun" || echo "[WARN] Failed to bring up ogstun"
else
    echo "[INFO] ogstun not found (may need to be created on host)"
fi

if ip link show ogstun2 > /dev/null 2>&1; then
    echo "[INFO] Configuring ogstun2..."
    ip addr add 10.46.0.1/16 dev ogstun2 2>/dev/null && echo "[OK] Added IPv4 to ogstun2" || echo "[WARN] Failed to add IPv4 to ogstun2"
    ip addr add 2001:db8:babe::1/48 dev ogstun2 2>/dev/null && echo "[OK] Added IPv6 to ogstun2" || echo "[WARN] Failed to add IPv6 to ogstun2"
    ip link set ogstun2 up 2>/dev/null && echo "[OK] Brought up ogstun2" || echo "[WARN] Failed to bring up ogstun2"
else
    echo "[INFO] ogstun2 not found (may need to be created on host)"
fi

if ip link show ogstun3 > /dev/null 2>&1; then
    echo "[INFO] Configuring ogstun3..."
    ip addr add 10.47.0.1/16 dev ogstun3 2>/dev/null && echo "[OK] Added IPv4 to ogstun3" || echo "[WARN] Failed to add IPv4 to ogstun3"
    ip addr add 2001:db8:face::1/48 dev ogstun3 2>/dev/null && echo "[OK] Added IPv6 to ogstun3" || echo "[WARN] Failed to add IPv6 to ogstun3"
    ip link set ogstun3 up 2>/dev/null && echo "[OK] Brought up ogstun3" || echo "[WARN] Failed to bring up ogstun3"
else
    echo "[INFO] ogstun3 not found (may need to be created on host)"
fi

# ============================================================================
# MongoDB Configuration (optional, only if not using external MongoDB)
# ============================================================================

# Check if SKIP_MONGODB env var is set (for use with external MongoDB in docker-compose)
if [ "$SKIP_MONGODB" != "true" ]; then
    echo "[INFO] Setting up local MongoDB..."
    mkdir -p /var/log /var/lib/mongodb
    
    if mongod --fork --logpath /var/log/mongodb.log --dbpath /var/lib/mongodb 2>/dev/null; then
        echo "[OK] MongoDB started successfully"
    else
        echo "[WARN] Failed to start local MongoDB (check /var/log/mongodb.log)"
    fi
else
    echo "[INFO] Skipping local MongoDB (using external instance)"
fi

# ============================================================================
# Ready for interaction
# ============================================================================

echo ""
echo "=========================================="
echo "[OK] Open5GS container ready"
echo "=========================================="
echo ""

if [ "$#" -gt 0 ]; then
    echo "[INFO] Executing command: $*"
    exec "$@"
fi

echo "[INFO] No command provided, starting interactive shell"
exec /bin/bash
