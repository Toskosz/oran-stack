#!/bin/bash

# ========================================================================
# O-RAN Stack - Health Check Script
# ========================================================================
# This script checks the health and status of all running containers
# across the three stacks: 5G Core, Near-RT RIC, and CU/DU Split.
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
# Configuration - 5G Core
# ========================================================================

declare -a CORE_SERVICES=(
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

declare -a CORE_IPS=(
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
  "172.20.0.8"    # HSS
  "172.20.0.21"   # PCRF
)

declare -A CORE_NAMES=(
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
# Configuration - Near-RT RIC
# ========================================================================

declare -a RIC_SERVICES=(
  "ric-dbaas"
  "ric-appmgr"
  "ric-e2term"
  "ric-e2mgr"
  "ric-rtmgr"
  "ric-submgr"
  "ric-a1mediator"
)

declare -a RIC_IPS=(
  "172.22.0.214"  # dbaas
  "172.22.0.216"  # appmgr
  "172.22.0.210"  # e2term
  "172.22.0.211"  # e2mgr
  "172.22.0.213"  # rtmgr
  "172.22.0.212"  # submgr
  "172.22.0.215"  # a1mediator
)

declare -A RIC_NAMES=(
  ["ric-dbaas"]="DBAAS (Redis)"
  ["ric-appmgr"]="App Manager"
  ["ric-e2term"]="E2 Termination"
  ["ric-e2mgr"]="E2 Manager"
  ["ric-rtmgr"]="Routing Mgr"
  ["ric-submgr"]="Subscription Mgr"
  ["ric-a1mediator"]="A1 Mediator"
)

# ========================================================================
# Configuration - CU/DU Split + UE
# ========================================================================

declare -a RAN_SERVICES=(
  "srs_cu"
  "srs_du"
  "srsue_5g_zmq"
)

declare -a RAN_IPS=(
  "172.21.0.50 / 172.20.0.50"  # CU (ran + core)
  "172.21.0.51 / 172.22.0.51"  # DU (ran + ric)
  "172.21.0.34"                 # UE (ran)
)

declare -A RAN_NAMES=(
  ["srs_cu"]="CU (srscu)"
  ["srs_du"]="DU (srsdu)"
  ["srsue_5g_zmq"]="UE (srsue)"
)

# ========================================================================
# Functions
# ========================================================================

echo_header() {
  echo -e "${BLUE}${1}${NC}"
}

echo_success() {
  echo -e "${GREEN}+${NC} $1"
}

echo_error() {
  echo -e "${RED}-${NC} $1"
}

echo_warning() {
  echo -e "${YELLOW}!${NC} $1"
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

check_stack() {
  local stack_name=$1
  shift
  local -n services=$1
  shift
  local -n ips=$1
  shift
  local -n names=$1

  local running=0
  local stopped=0
  local missing=0

  echo ""
  echo -e "${CYAN}=== ${stack_name} ===${NC}"
  echo ""

  for i in "${!services[@]}"; do
    local service=${services[$i]}
    local status=$(get_container_status "$service")
    local display_name="${names[$service]}"
    local ip="${ips[$i]}"

    printf "  %-20s " "$display_name"

    case $status in
      "running")
        echo_success "Running  (${ip})"
        running=$((running + 1))
        ;;
      "stopped")
        echo_error "Stopped  (${ip})"
        stopped=$((stopped + 1))
        ;;
      "missing")
        echo_warning "Missing"
        missing=$((missing + 1))
        ;;
    esac
  done

  echo ""
  printf "  Total: %d | " "${#services[@]}"
  echo -en "${GREEN}Running: $running${NC}"
  if [ $stopped -gt 0 ]; then
    echo -en " | ${RED}Stopped: $stopped${NC}"
  fi
  if [ $missing -gt 0 ]; then
    echo -en " | ${YELLOW}Missing: $missing${NC}"
  fi
  echo ""
}

display_health_report() {
  clear
  echo ""
  echo_header "=================================================================="
  echo_header "         O-RAN Stack - Container Health Report"
  echo_header "=================================================================="

  # 5G Core
  check_stack "5G Core Network" CORE_SERVICES CORE_IPS CORE_NAMES

  # Near-RT RIC
  check_stack "Near-RT RIC Platform" RIC_SERVICES RIC_IPS RIC_NAMES

  # CU/DU + UE
  check_stack "CU/DU Split + UE" RAN_SERVICES RAN_IPS RAN_NAMES

  # Network status
  echo ""
  echo -e "${CYAN}=== Networks ===${NC}"
  echo ""
  for net in 5g-core-network ric-network ran-network; do
    if docker network inspect "$net" &>/dev/null; then
      local subnet=$(docker network inspect "$net" --format='{{range .IPAM.Config}}{{.Subnet}}{{end}}')
      local count=$(docker network inspect "$net" --format='{{len .Containers}}')
      printf "  %-20s " "$net"
      echo_success "Active ($subnet, $count containers)"
    else
      printf "  %-20s " "$net"
      echo_warning "Not created"
    fi
  done
  echo ""

  # MongoDB status
  echo -e "${CYAN}=== Key Services ===${NC}"
  echo ""
  if docker ps --format "{{.Names}}" | grep -q "^5g-mongodb$"; then
    if docker exec 5g-mongodb mongosh --eval 'db.adminCommand("ping")' &>/dev/null; then
      printf "  %-20s " "MongoDB"
      echo_success "Healthy"
    else
      printf "  %-20s " "MongoDB"
      echo_warning "Running but not responding"
    fi
  else
    printf "  %-20s " "MongoDB"
    echo_error "Not running"
  fi

  # Redis/DBAAS status
  if docker ps --format "{{.Names}}" | grep -q "^ric-dbaas$"; then
    if docker exec ric-dbaas redis-cli ping &>/dev/null; then
      printf "  %-20s " "RIC Redis/SDL"
      echo_success "Healthy"
    else
      printf "  %-20s " "RIC Redis/SDL"
      echo_warning "Running but not responding"
    fi
  else
    printf "  %-20s " "RIC Redis/SDL"
    echo_error "Not running"
  fi
  echo ""

  if [ "$1" = "watch" ]; then
    echo_header "------------------------------------------------------------------"
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
