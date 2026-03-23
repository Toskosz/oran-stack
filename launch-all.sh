#!/bin/bash

# ============================================================================
# O-RAN Stack - Full Deployment Launcher
# ============================================================================
# Orchestrates startup of all three docker-compose stacks in the correct order:
#   1. 5G Core    (docker-compose.yml)       - AMF must be ready first
#   2. Near-RT RIC (docker-compose.ric.yml)  - E2 termination must be up
#   3. CU/DU + UE  (docker-compose.cudu.yml) - connects to core and RIC
#
# Usage:
#   ./launch-all.sh [options]
#
# Options:
#   --core-only    Start only the 5G core
#   --no-ue        Start core + RIC + CU/DU but skip the UE
#   --down         Stop all stacks (reverse order)
#   --status       Show status of all containers
#   --logs         Export logs after startup
#   -h, --help     Show this help message
# ============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Compose files
CORE_COMPOSE="docker-compose.yml"
RIC_COMPOSE="docker-compose.ric.yml"
CUDU_COMPOSE="docker-compose.cudu.yml"

# ============================================================================
# Helper Functions
# ============================================================================

print_banner() {
  echo -e "${BLUE}╔════════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BLUE}║          O-RAN Stack - Full Deployment Launcher              ║${NC}"
  echo -e "${BLUE}╚════════════════════════════════════════════════════════════════╝${NC}"
  echo ""
}

log_info() {
  echo -e "${BLUE}[*]${NC} $1"
}

log_success() {
  echo -e "${GREEN}[+]${NC} $1"
}

log_warn() {
  echo -e "${YELLOW}[!]${NC} $1"
}

log_error() {
  echo -e "${RED}[-]${NC} $1"
}

check_docker() {
  if ! docker ps &>/dev/null; then
    log_error "Docker daemon is not running. Please start Docker first."
    exit 1
  fi
  log_success "Docker is running"
}

check_images() {
  local missing=0

  if ! docker image inspect teste-core:latest &>/dev/null; then
    log_warn "Image 'teste-core:latest' not found. Build it with:"
    echo "    docker build -f Dockerfile.5gscore -t teste-core:latest ."
    missing=1
  fi

  if [ "$1" != "--core-only" ]; then
    if ! docker image inspect srsran-split:latest &>/dev/null; then
      log_warn "Image 'srsran-split:latest' not found. Build it with:"
      echo "    docker build -f Dockerfile.srsran -t srsran-split:latest ."
      missing=1
    fi

    if ! docker image inspect srsue:latest &>/dev/null; then
      log_warn "Image 'srsue:latest' not found. Build it with:"
      echo "    docker build -f Dockerfile.srsue -t srsue:latest ."
      missing=1
    fi
  fi

  if [ $missing -eq 1 ]; then
    log_error "Missing Docker images. Build them before running this script."
    exit 1
  fi

  log_success "All required Docker images are available"
}

wait_for_container() {
  local container=$1
  local timeout=${2:-60}
  local elapsed=0

  while [ $elapsed -lt $timeout ]; do
    if docker ps --format "{{.Names}}" | grep -q "^${container}$"; then
      return 0
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done

  log_error "Timeout waiting for container '$container' to start"
  return 1
}

wait_for_healthy() {
  local container=$1
  local timeout=${2:-120}
  local elapsed=0

  log_info "Waiting for $container to become healthy..."
  while [ $elapsed -lt $timeout ]; do
    local health=$(docker inspect --format='{{.State.Health.Status}}' "$container" 2>/dev/null || echo "none")
    if [ "$health" = "healthy" ]; then
      return 0
    elif [ "$health" = "none" ]; then
      # No health check defined, just check if running
      if docker ps --format "{{.Names}}" | grep -q "^${container}$"; then
        return 0
      fi
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done

  log_warn "Timeout waiting for $container to become healthy (may still be starting)"
  return 0
}

# ============================================================================
# Stack Operations
# ============================================================================

start_core() {
  log_info "Starting 5G Core Network..."
  docker compose -f "$CORE_COMPOSE" up -d
  echo ""

  # Wait for MongoDB to be healthy (critical dependency)
  wait_for_healthy "5g-mongodb" 60

  # Brief pause for NFs to register with NRF
  log_info "Waiting for core NFs to initialize (10s)..."
  sleep 10

  log_success "5G Core Network is up"
  echo ""
}

start_ric() {
  log_info "Starting Near-RT RIC Platform..."
  docker compose -f "$RIC_COMPOSE" up -d
  echo ""

  # Wait for Redis/dbaas to be healthy
  wait_for_healthy "ric-dbaas" 30

  # Brief pause for RIC components to initialize
  log_info "Waiting for RIC platform to initialize (10s)..."
  sleep 10

  log_success "Near-RT RIC Platform is up"
  echo ""
}

start_cudu() {
  local skip_ue=$1

  if [ "$skip_ue" = "true" ]; then
    log_info "Starting CU and DU (without UE)..."
    docker compose -f "$CUDU_COMPOSE" up -d srs_cu srs_du
  else
    log_info "Starting CU, DU, and UE..."
    docker compose -f "$CUDU_COMPOSE" up -d
  fi
  echo ""

  # Wait for CU to start, then DU
  wait_for_container "srs_cu" 30
  wait_for_container "srs_du" 30

  log_info "Waiting for F1/E2 interfaces to establish (10s)..."
  sleep 10

  log_success "CU/DU Split is up"
  echo ""
}

stop_all() {
  log_info "Stopping all stacks (reverse order)..."
  echo ""

  log_info "Stopping CU/DU + UE..."
  docker compose -f "$CUDU_COMPOSE" down 2>/dev/null || true

  log_info "Stopping Near-RT RIC..."
  docker compose -f "$RIC_COMPOSE" down 2>/dev/null || true

  log_info "Stopping 5G Core..."
  docker compose -f "$CORE_COMPOSE" down 2>/dev/null || true

  echo ""
  log_success "All stacks stopped"
}

show_status() {
  echo ""
  echo -e "${CYAN}=== 5G Core ===${NC}"
  docker compose -f "$CORE_COMPOSE" ps 2>/dev/null || echo "  (not running)"
  echo ""
  echo -e "${CYAN}=== Near-RT RIC ===${NC}"
  docker compose -f "$RIC_COMPOSE" ps 2>/dev/null || echo "  (not running)"
  echo ""
  echo -e "${CYAN}=== CU/DU + UE ===${NC}"
  docker compose -f "$CUDU_COMPOSE" ps 2>/dev/null || echo "  (not running)"
  echo ""

  # Network summary
  echo -e "${CYAN}=== Networks ===${NC}"
  for net in 5g-core-network ric-network ran-network; do
    if docker network inspect "$net" &>/dev/null; then
      local subnet=$(docker network inspect "$net" --format='{{range .IPAM.Config}}{{.Subnet}}{{end}}')
      local count=$(docker network inspect "$net" --format='{{len .Containers}}')
      echo -e "  ${GREEN}+${NC} $net ($subnet) - $count containers"
    else
      echo -e "  ${RED}-${NC} $net (not created)"
    fi
  done
  echo ""
}

show_help() {
  echo "Usage: ./launch-all.sh [options]"
  echo ""
  echo "Options:"
  echo "  --core-only    Start only the 5G core"
  echo "  --no-ue        Start core + RIC + CU/DU but skip the UE"
  echo "  --down         Stop all stacks (reverse order)"
  echo "  --status       Show status of all containers"
  echo "  --logs         Export logs after startup"
  echo "  -h, --help     Show this help message"
  echo ""
  echo "Startup order:"
  echo "  1. 5G Core    (docker-compose.yml)"
  echo "  2. Near-RT RIC (docker-compose.ric.yml)"
  echo "  3. CU/DU + UE  (docker-compose.cudu.yml)"
  echo ""
  echo "Required images (build before first run):"
  echo "  docker build -f Dockerfile.5gscore -t teste-core:latest ."
  echo "  docker build -f Dockerfile.srsran -t srsran-split:latest ."
  echo "  docker build -f Dockerfile.srsue -t srsue:latest ."
}

# ============================================================================
# Main
# ============================================================================

print_banner

case "${1:-}" in
  --down)
    check_docker
    stop_all
    ;;
  --status)
    check_docker
    show_status
    ;;
  --core-only)
    check_docker
    check_images "--core-only"
    start_core
    log_success "Deployment complete (core only)"
    ;;
  --no-ue)
    check_docker
    check_images
    start_core
    start_ric
    start_cudu "true"
    log_success "Deployment complete (without UE)"
    ;;
  -h|--help)
    show_help
    ;;
  "")
    check_docker
    check_images
    start_core
    start_ric
    start_cudu "false"
    log_success "Full O-RAN stack deployment complete!"
    echo ""
    echo -e "${CYAN}Architecture:${NC}"
    echo "  UE (172.21.0.34) --ZMQ--> DU (172.21.0.51) --F1--> CU (172.21.0.50)"
    echo "                              |                        |"
    echo "                              |--E2--> RIC (172.22.0.210)"
    echo "                                                       |--N2--> AMF (172.20.0.5)"
    echo ""
    echo -e "${CYAN}Useful commands:${NC}"
    echo "  ./launch-all.sh --status         # View all container status"
    echo "  ./launch-all.sh --down           # Stop everything"
    echo "  docker logs srs_cu               # View CU logs"
    echo "  docker logs srs_du               # View DU logs"
    echo "  docker logs ric-e2term           # View E2 termination logs"
    echo "  docker logs ric-e2mgr            # View E2 manager logs"
    echo "  curl -s http://localhost:3800/v1/nodeb/states  # Query RIC node states"
    echo ""

    if [ "$2" = "--logs" ] || [ "${1:-}" = "--logs" ]; then
      log_info "Exporting logs..."
      ./scripts/export-logs.sh 2>/dev/null || true
    fi
    ;;
  --logs)
    check_docker
    check_images
    start_core
    start_ric
    start_cudu "false"
    log_success "Full O-RAN stack deployment complete!"
    log_info "Exporting logs..."
    ./scripts/export-logs.sh 2>/dev/null || true
    ;;
  *)
    log_error "Unknown option: $1"
    show_help
    exit 1
    ;;
esac
