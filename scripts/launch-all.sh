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
#   --ric-restart  Safely restart only the RIC (flush Redis + ordered restart)
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
    echo "    docker build -f dockerfiles/Dockerfile.5gscore -t teste-core:latest ."
    missing=1
  fi

  if [ "$1" != "--core-only" ]; then
    if ! docker image inspect srsran-split:latest &>/dev/null; then
      log_warn "Image 'srsran-split:latest' not found. Build it with:"
      echo "    docker build -f dockerfiles/Dockerfile.srsran -t srsran-split:latest ."
      missing=1
    fi

    if ! docker image inspect srsue:latest &>/dev/null; then
      log_warn "Image 'srsue:latest' not found. Build it with:"
      echo "    docker build -f dockerfiles/Dockerfile.srsue -t srsue:latest ."
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

wait_for_e2t() {
  # Poll e2mgr REST API until an E2T instance appears, confirming the full
  # E2_TERM_INIT → rtmgr registration → keep-alive flow completed successfully.
  # This is the definitive signal that the RIC is ready to accept E2 Setup from the DU.
  local timeout=${1:-90}
  local elapsed=0

  log_info "Waiting for E2T instance to register with e2mgr (up to ${timeout}s)..."
  while [ $elapsed -lt $timeout ]; do
    local e2t
    e2t=$(docker exec ric-e2mgr curl -s http://localhost:3800/v1/e2t/list 2>/dev/null || echo "[]")
    if [ "$e2t" != "[]" ] && [ -n "$e2t" ]; then
      log_success "E2T instance registered: $e2t"
      return 0
    fi
    sleep 3
    elapsed=$((elapsed + 3))
  done

  log_warn "E2T instance not registered after ${timeout}s — DU may fail to connect."
  log_warn "Diagnose: docker exec ric-e2mgr curl -s http://localhost:3800/v1/e2t/list"
  log_warn "If stuck, run: ./launch-all.sh --ric-restart"
}

ric_reboot_dance() {
  # Safe RIC restart order from LEARNINGS-TIMING-RACE.md:
  # e2term sends E2_TERM_INIT only ONCE on boot, so order is critical.
  # Stale Redis E2T entries cause rtmgr desync, so flush first.
  log_info "RIC Reboot Dance: flushing Redis and restarting RIC in safe order..."
  echo ""

  # Step 1: Flush Redis to clear stale E2T/routing state
  log_info "Flushing Redis (clearing stale E2T state)..."
  docker exec ric-dbaas redis-cli FLUSHALL
  log_success "Redis flushed"

  # Step 2: Restart e2mgr first — rtmgr needs it healthy before querying /v1/e2t/list
  log_info "Restarting ric-e2mgr..."
  docker restart ric-e2mgr
  wait_for_healthy "ric-e2mgr" 60

  # Step 3: Restart rtmgr — starts reconciliation loop against a clean e2mgr
  log_info "Restarting ric-rtmgr..."
  docker restart ric-rtmgr
  # rtmgr has no healthcheck; give it a moment to bind RMR and start reconciling
  sleep 5

  # Step 4: Restart e2term LAST — it sends E2_TERM_INIT only once on boot;
  # if it starts before rtmgr's RMR is up, the message is lost forever
  log_info "Restarting ric-e2term (last — sends E2_TERM_INIT only once on boot)..."
  docker restart ric-e2term
  wait_for_healthy "ric-e2term" 60

  echo ""
  wait_for_e2t 90
}

start_ric() {
  log_info "Starting Near-RT RIC Platform..."

  # Flush Redis if dbaas is already running. Handles the partial-down case where
  # dbaas survived but the RIC app containers were stopped — stale E2T entries
  # would cause rtmgr desync and the keep-alive death spiral on restart.
  # On a full cold start (after --down) dbaas is recreated so Redis is already
  # empty, but FLUSHALL on an empty db is harmless.
  if docker ps --format "{{.Names}}" | grep -q "^ric-dbaas$"; then
    log_info "Flushing stale Redis state before RIC startup..."
    docker exec ric-dbaas redis-cli FLUSHALL
  fi

  # depends_on in docker-compose.ric.yml enforces:
  #   dbaas (healthy) → e2mgr (healthy) → rtmgr
  #                                      → e2term (+5s sleep, healthy)
  docker compose -f "$RIC_COMPOSE" up -d
  echo ""

  # Wait for Redis/dbaas to be healthy
  wait_for_healthy "ric-dbaas" 30

  # Wait for e2mgr REST+RMR to be ready (gates e2term startup via depends_on)
  wait_for_healthy "ric-e2mgr" 90

  # Wait for e2term SCTP+RMR path to be confirmed healthy before starting the DU.
  # This prevents the E2 Setup Request race condition where the DU connects before
  # e2term's RMR link to e2mgr is established, causing a silent RMR_ERR_NOENDPT drop.
  wait_for_healthy "ric-e2term" 60

  # Verify the full E2T registration flow completed (e2term → RMR → e2mgr → rtmgr).
  # Only after this is the RIC ready to accept E2 Setup requests from the DU.
  wait_for_e2t 90

  log_success "Near-RT RIC Platform is up"
  echo ""
}

wait_for_nodeb() {
  # Poll e2mgr until at least one gNB appears in /v1/nodeb/states.
  # The DU sends E2 Setup Request only once on SCTP connect. If e2term's SCTP
  # handler wasn't fully ready, the message is silently lost. Detecting this here
  # lets start_cudu() restart the DU to trigger a fresh E2 Setup Request.
  local timeout=${1:-30}
  local elapsed=0

  while [ $elapsed -lt $timeout ]; do
    local states
    states=$(docker exec ric-e2mgr curl -s http://localhost:3800/v1/nodeb/states 2>/dev/null || echo "[]")
    if [ "$states" != "[]" ] && [ -n "$states" ]; then
      log_success "gNB registered: $states"
      return 0
    fi
    sleep 3
    elapsed=$((elapsed + 3))
  done

  return 1
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

  # Verify the DU's E2 Setup Request was processed by e2mgr.
  # The DU sends E2 Setup only once on initial SCTP connect — if e2term's SCTP
  # handler wasn't fully ready, the message is silently lost and nodeb/states
  # stays empty. One DU restart is enough to trigger a fresh E2 Setup.
  log_info "Waiting for gNB to appear in e2mgr nodeb/states (up to 30s)..."
  if ! wait_for_nodeb 30; then
    log_warn "E2 Setup Request not processed — restarting DU to retrigger (one-shot message)..."
    docker restart srs_du
    log_info "Waiting for gNB after DU restart (up to 30s)..."
    if ! wait_for_nodeb 30; then
      log_warn "gNB still not registered. Check: docker exec ric-e2mgr curl -s http://localhost:3800/v1/nodeb/states"
    fi
  fi

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
  echo "  --ric-restart  Safely restart only the RIC (flush Redis + ordered restart)"
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
  echo "  docker build -f dockerfiles/Dockerfile.5gscore -t teste-core:latest ."
  echo "  docker build -f dockerfiles/Dockerfile.srsran -t srsran-split:latest ."
  echo "  docker build -f dockerfiles/Dockerfile.srsue -t srsue:latest ."
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
  --ric-restart)
    check_docker
    ric_reboot_dance
    log_success "RIC restarted safely"
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
    echo -e "${CYAN}Verify deployment with:${NC}"
    echo "  docker exec ric-e2mgr curl -s http://localhost:3800/v1/nodeb/states"
    echo "  docker exec ric-e2mgr curl -s http://localhost:3800/v1/e2t/list"
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
