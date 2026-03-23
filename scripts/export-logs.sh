#!/bin/bash

# ========================================================================
# 5G Core Docker Compose - Log Export & Health Check Script
# ========================================================================
# This script exports container logs and creates a startup summary
# It should be run after "docker-compose up -d" completes
# Usage: ./scripts/export-logs.sh
# ========================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
LOG_DIR="$PROJECT_DIR/logs"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ========================================================================
# Configuration
# ========================================================================

# 5G Core NFs in startup order
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

# NF Display Names
declare -A NF_NAMES=(
  ["5g-mongodb"]="MongoDB"
  ["5g-core-nrf"]="NRF (Network Repository Function)"
  ["5g-core-scp"]="SCP (Service Communication Proxy)"
  ["5g-core-sepp"]="SEPP (Security Edge Protection Proxy)"
  ["5g-core-amf"]="AMF (Access and Mobility Function)"
  ["5g-core-smf"]="SMF (Session Management Function)"
  ["5g-core-upf"]="UPF (User Plane Function)"
  ["5g-core-ausf"]="AUSF (Authentication Server Function)"
  ["5g-core-udm"]="UDM (Unified Data Management)"
  ["5g-core-pcf"]="PCF (Policy Control Function)"
  ["5g-core-nssf"]="NSSF (Network Slice Selection Function)"
  ["5g-core-bsf"]="BSF (Binding Support Function)"
  ["5g-core-udr"]="UDR (Unified Data Repository)"
  ["5g-core-mme"]="MME (Mobility Management Entity)"
  ["5g-core-sgwc"]="SGW-C (Serving Gateway - Control)"
  ["5g-core-sgwu"]="SGW-U (Serving Gateway - User)"
  ["5g-core-hss"]="HSS (Home Subscriber Server)"
  ["5g-core-pcrf"]="PCRF (Policy and Charging Rules Function)"
)

# ========================================================================
# Functions
# ========================================================================

echo_info() {
  echo -e "${BLUE}[INFO]${NC} $1"
}

echo_success() {
  echo -e "${GREEN}[OK]${NC} $1"
}

echo_warn() {
  echo -e "${YELLOW}[WARN]${NC} $1"
}

echo_error() {
  echo -e "${RED}[ERROR]${NC} $1"
}

create_logs_dir() {
  if [ ! -d "$LOG_DIR" ]; then
    echo_info "Creating logs directory: $LOG_DIR"
    mkdir -p "$LOG_DIR"
  fi
}

export_container_logs() {
  local container=$1
  local log_file="$LOG_DIR/${container}_${TIMESTAMP}.log"
  
  if docker ps -a --format "{{.Names}}" | grep -q "^${container}$"; then
    echo_info "Exporting logs for $container..."
    docker logs "$container" > "$log_file" 2>&1
    echo_success "Logs exported to $log_file"
    return 0
  else
    echo_warn "Container $container not found"
    return 1
  fi
}

check_container_status() {
  local container=$1
  
  if docker ps --format "{{.Names}}" | grep -q "^${container}$"; then
    echo "running"
  elif docker ps -a --format "{{.Names}}" | grep -q "^${container}$"; then
    echo "stopped"
  else
    echo "missing"
  fi
}

get_container_exit_code() {
  local container=$1
  docker inspect "$container" --format='{{.State.ExitCode}}' 2>/dev/null || echo "N/A"
}

wait_for_service() {
  local container=$1
  local max_wait=30
  local elapsed=0
  
  while [ $elapsed -lt $max_wait ]; do
    if docker ps --format "{{.Names}}" | grep -q "^${container}$"; then
      return 0
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done
  
  return 1
}

# ========================================================================
# Main Execution
# ========================================================================

echo ""
echo "========================================================================"
echo "5G Core Docker Compose - Log Export & Health Check"
echo "========================================================================"
echo ""

create_logs_dir

# Check if docker-compose file exists
if [ ! -f "$PROJECT_DIR/docker-compose.yml" ]; then
  echo_error "docker-compose.yml not found in $PROJECT_DIR"
  exit 1
fi

echo_info "Log directory: $LOG_DIR"
echo_info "Timestamp: $TIMESTAMP"
echo ""

# ========================================================================
# Export Container Logs
# ========================================================================

echo "========================================================================"
echo "Exporting Container Logs..."
echo "========================================================================"
echo ""

for service in "${NF_SERVICES[@]}"; do
  export_container_logs "$service"
done

echo ""

# ========================================================================
# Generate Startup Summary
# ========================================================================

SUMMARY_FILE="$LOG_DIR/startup_summary_${TIMESTAMP}.log"

echo "========================================================================"
echo "Generating Startup Summary..."
echo "========================================================================"
echo ""

{
  echo "========================================================================="
  echo "5G Core Docker Compose - Startup Summary"
  echo "========================================================================="
  echo "Timestamp: $(date)"
  echo "Project Directory: $PROJECT_DIR"
  echo ""
  echo "Container Status Report:"
  echo "========================================================================="
  echo ""
  
  local running_count=0
  local stopped_count=0
  local missing_count=0
  
  for i in "${!NF_SERVICES[@]}"; do
    local service=${NF_SERVICES[$i]}
    local order=$((i + 1))
    local status=$(check_container_status "$service")
    local display_name="${NF_NAMES[$service]}"
    
    case $status in
      "running")
        echo "[$order] ✓ $display_name"
        echo "    Status: RUNNING"
        echo "    Container: $service"
        running_count=$((running_count + 1))
        ;;
      "stopped")
        local exit_code=$(get_container_exit_code "$service")
        echo "[$order] ✗ $display_name"
        echo "    Status: STOPPED (Exit Code: $exit_code)"
        echo "    Container: $service"
        stopped_count=$((stopped_count + 1))
        ;;
      "missing")
        echo "[$order] ? $display_name"
        echo "    Status: NOT FOUND"
        echo "    Container: $service"
        missing_count=$((missing_count + 1))
        ;;
    esac
    echo ""
  done
  
  echo "========================================================================="
  echo "Summary:"
  echo "========================================================================="
  echo "Running: $running_count"
  echo "Stopped: $stopped_count"
  echo "Missing: $missing_count"
  echo "Total: ${#NF_SERVICES[@]}"
  echo ""
  
  if [ $stopped_count -gt 0 ] || [ $missing_count -gt 0 ]; then
    echo "⚠ WARNING: Not all containers are running!"
    echo ""
    echo "To view container logs, run:"
    echo "  docker logs <container-name>"
    echo ""
    echo "To restart failed containers, run:"
    echo "  docker-compose restart"
    echo ""
  fi
  
  echo "========================================================================="
  echo "Docker Network Information:"
  echo "========================================================================="
  docker network inspect 5g-core-network 2>/dev/null || echo "Network not found"
  echo ""
  
  echo "========================================================================="
  echo "MongoDB Status:"
  echo "========================================================================="
  docker exec 5g-mongodb mongosh --eval 'db.adminCommand("ping")' 2>/dev/null || echo "MongoDB not accessible"
  echo ""
  
} | tee "$SUMMARY_FILE"

echo ""
echo_success "Startup summary exported to $SUMMARY_FILE"
echo ""

# ========================================================================
# Display Summary Statistics
# ========================================================================

echo "========================================================================"
echo "Summary Statistics"
echo "========================================================================"
echo ""

running_count=$(docker ps --format "{{.Names}}" | grep -c "^5g-" || true)
total_count=${#NF_SERVICES[@]}

echo_info "Running Containers: $running_count/$total_count"
echo_info "Log Directory: $LOG_DIR"
echo_info "Latest Summary: $SUMMARY_FILE"
echo ""

if [ $running_count -eq $total_count ]; then
  echo_success "All containers are running!"
else
  echo_warn "Some containers are not running. Check logs for details."
fi

echo ""
echo "========================================================================"
echo "Useful Commands:"
echo "========================================================================"
echo "View all logs:            ls -lah $LOG_DIR"
echo "View specific container:  docker logs 5g-core-nrf"
echo "Follow logs in real-time: docker logs -f 5g-core-nrf"
echo "Check network:            docker network inspect 5g-core-network"
echo "View startup summary:     cat $SUMMARY_FILE"
echo ""
