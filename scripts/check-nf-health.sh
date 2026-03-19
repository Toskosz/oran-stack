#!/bin/bash

# ========================================================================
# 5G Core Docker Compose - Health Check Script
# ========================================================================
# This script checks the health and status of all running NF containers
# Usage: ./scripts/check-nf-health.sh [watch]
# Arguments:
#   watch - Continuously monitor container health (press Ctrl+C to exit)
# ========================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ========================================================================
# Configuration
# ========================================================================

declare -a NF_SERVICES=(
  "5g-mongodb"
  "5g-core-nrf"
  "5g-core-scp"
  "5g-core-sepp"
  "5g-core-amf"
  "5g-core-smf"
  "5g-core-upf"
  "5g-core-ausf"
  "5g-core-udm"
  "5g-core-pcf"
  "5g-core-nssf"
  "5g-core-bsf"
  "5g-core-udr"
  "5g-core-mme"
  "5g-core-sgwc"
  "5g-core-sgwu"
  "5g-core-hss"
  "5g-core-pcrf"
)

declare -a NF_PORTS=(
  "27017"  # MongoDB
  "7777"   # NRF
  "7777"   # SCP
  "7777"   # SEPP
  "7777"   # AMF
  "7777"   # SMF
  "2152"   # UPF
  "7777"   # AUSF
  "7777"   # UDM
  "7777"   # PCF
  "7777"   # NSSF
  "7777"   # BSF
  "7777"   # UDR
  "2123"   # MME
  "2123"   # SGW-C
  "2152"   # SGW-U
  ""       # HSS
  ""       # PCRF
)

declare -a NF_IPS=(
  "172.20.0.254"  # MongoDB
  "172.20.0.10"   # NRF
  "172.20.0.200"  # SCP
  "172.20.0.250"  # SEPP
  "172.20.0.5"    # AMF
  "172.20.0.4"    # SMF
  "172.20.0.7"    # UPF
  "172.20.0.11"   # AUSF
  "172.20.0.12"   # UDM
  "172.20.0.13"   # PCF
  "172.20.0.14"   # NSSF
  "172.20.0.15"   # BSF
  "172.20.0.20"   # UDR
  "172.20.0.2"    # MME
  "172.20.0.3"    # SGW-C
  "172.20.0.6"    # SGW-U
  "172.20.0.1"    # HSS
  "172.20.0.21"   # PCRF
)

declare -A NF_NAMES=(
  ["5g-mongodb"]="MongoDB"
  ["5g-core-nrf"]="NRF"
  ["5g-core-scp"]="SCP"
  ["5g-core-sepp"]="SEPP"
  ["5g-core-amf"]="AMF"
  ["5g-core-smf"]="SMF"
  ["5g-core-upf"]="UPF"
  ["5g-core-ausf"]="AUSF"
  ["5g-core-udm"]="UDM"
  ["5g-core-pcf"]="PCF"
  ["5g-core-nssf"]="NSSF"
  ["5g-core-bsf"]="BSF"
  ["5g-core-udr"]="UDR"
  ["5g-core-mme"]="MME"
  ["5g-core-sgwc"]="SGW-C"
  ["5g-core-sgwu"]="SGW-U"
  ["5g-core-hss"]="HSS"
  ["5g-core-pcrf"]="PCRF"
)

# ========================================================================
# Functions
# ========================================================================

echo_header() {
  echo -e "${BLUE}${1}${NC}"
}

echo_success() {
  echo -e "${GREEN}✓${NC} $1"
}

echo_error() {
  echo -e "${RED}✗${NC} $1"
}

echo_warning() {
  echo -e "${YELLOW}⚠${NC} $1"
}

get_container_status() {
  local container=$1
  
  if docker ps --format "{{.Names}}" | grep -q "^${container}$"; then
    echo "running"
  elif docker ps -a --format "{{.Names}}" | grep -q "^${container}$"; then
    echo "stopped"
  else
    echo "missing"
  fi
}

get_container_uptime() {
  local container=$1
  
  if docker ps --format "{{.Names}}" | grep -q "^${container}$"; then
    docker inspect "$container" --format='{{.State.StartedAt}}' 2>/dev/null | sed 's/T/ /g' | sed 's/Z//g'
  else
    echo "N/A"
  fi
}

check_port_reachable() {
  local ip=$1
  local port=$2
  local container=$3
  
  if [ -z "$port" ]; then
    return 1
  fi
  
  # Try to reach the port from inside the container
  if docker exec "$container" timeout 2 bash -c "echo > /dev/tcp/$ip/$port" 2>/dev/null; then
    return 0
  else
    return 1
  fi
}

display_health_report() {
  clear
  echo ""
  echo_header "╔════════════════════════════════════════════════════════════════════════════════╗"
  echo_header "║         5G Core Docker Compose - Container Health Report                       ║"
  echo_header "╚════════════════════════════════════════════════════════════════════════════════╝"
  echo ""
  
  local running_count=0
  local stopped_count=0
  local missing_count=0
  
  for i in "${!NF_SERVICES[@]}"; do
    local service=${NF_SERVICES[$i]}
    local status=$(get_container_status "$service")
    local uptime=$(get_container_uptime "$service")
    local display_name="${NF_NAMES[$service]}"
    
    printf "%-12s " "[$((i+1))]"
    printf "%-12s " "$display_name"
    
    case $status in
      "running")
        echo_success "Running"
        running_count=$((running_count + 1))
        printf "  ├─ IP: %s\n" "${NF_IPS[$i]}"
        if [ -n "${NF_PORTS[$i]}" ]; then
          printf "  ├─ Port: %s\n" "${NF_PORTS[$i]}"
        fi
        printf "  └─ Started: %s\n" "$uptime"
        ;;
      "stopped")
        echo_error "Stopped"
        stopped_count=$((stopped_count + 1))
        printf "  └─ Container exists but is not running\n"
        ;;
      "missing")
        echo_warning "Missing"
        missing_count=$((missing_count + 1))
        printf "  └─ Container not found\n"
        ;;
    esac
    echo ""
  done
  
  echo_header "────────────────────────────────────────────────────────────────────────────────"
  echo ""
  printf "Total: %d | " "${#NF_SERVICES[@]}"
  echo -en "${GREEN}Running: $running_count${NC} | "
  if [ $stopped_count -gt 0 ]; then
    echo -en "${RED}Stopped: $stopped_count${NC} | "
  fi
  if [ $missing_count -gt 0 ]; then
    echo -en "${YELLOW}Missing: $missing_count${NC}"
  fi
  echo ""
  echo ""
  
  # Network status
  echo_header "Network Status:"
  if docker network inspect 5g-core-network &>/dev/null; then
    echo_success "5g-core-network is available"
    local subnet=$(docker network inspect 5g-core-network --format='{{range .IPAM.Config}}{{.Subnet}}{{end}}')
    printf "  └─ Subnet: %s\n\n" "$subnet"
  else
    echo_error "5g-core-network not found"
  fi
  
  # MongoDB status
  echo_header "MongoDB Status:"
  if docker ps --format "{{.Names}}" | grep -q "^5g-mongodb$"; then
    if docker exec 5g-mongodb mongosh --eval 'db.adminCommand("ping")' &>/dev/null; then
      echo_success "MongoDB is healthy and responsive"
    else
      echo_warning "MongoDB is running but not responding"
    fi
  else
    echo_error "MongoDB is not running"
  fi
  echo ""
  
  if [ "$1" = "watch" ]; then
    echo_header "────────────────────────────────────────────────────────────────────────────────"
    echo "Watch mode enabled. Refreshing every 5 seconds... (Press Ctrl+C to exit)"
  fi
}

watch_mode() {
  while true; do
    display_health_report "watch"
    sleep 5
  done
}

# ========================================================================
# Main Execution
# ========================================================================

if [ "$1" = "watch" ]; then
  watch_mode
else
  display_health_report
fi
