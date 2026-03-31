#!/bin/bash

# ========================================================================
# 5G Core Docker Compose - Launcher Script
# ========================================================================
# Convenience script to start the full 5G core and export logs
# Usage: ./launch-5g-core.sh [logs]
# Arguments:
#   logs - Also export logs and show health check after startup
# ========================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Color codes
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${BLUE}╔════════════════════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║              5G Core Docker Compose - Launcher Script                          ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Check if Docker is running
echo -e "${BLUE}[*] Checking Docker...${NC}"
if ! docker ps &>/dev/null; then
  echo -e "${YELLOW}[!] Docker daemon is not running. Please start Docker first.${NC}"
  exit 1
fi
echo -e "${GREEN}[✓] Docker is running${NC}"
echo ""

# Check if docker-compose.yml exists
if [ ! -f "$SCRIPT_DIR/docker-compose.yml" ]; then
  echo -e "${YELLOW}[!] docker-compose.yml not found in $SCRIPT_DIR${NC}"
  exit 1
fi

echo -e "${BLUE}[*] Starting 5G Core containers...${NC}"
echo ""

# Start the containers
cd "$SCRIPT_DIR"
docker compose up -d

echo ""
echo -e "${GREEN}[✓] Containers started!${NC}"
echo ""

# Wait a bit for containers to initialize
echo -e "${BLUE}[*] Waiting for containers to initialize (5 seconds)...${NC}"
sleep 5

# Export logs if requested
if [ "$1" = "logs" ]; then
  echo ""
  echo -e "${BLUE}[*] Exporting logs and generating startup summary...${NC}"
  echo ""
  ./scripts/export-logs.sh
  
  echo ""
  echo -e "${BLUE}[*] Health check status:${NC}"
  echo ""
  ./scripts/check-nf-health.sh
else
  echo -e "${BLUE}[*] To export logs and view health status, run:${NC}"
  echo -e "${GREEN}    ./launch-5g-core.sh logs${NC}"
  echo ""
  echo -e "${BLUE}[*] Or manually:${NC}"
  echo -e "${GREEN}    ./scripts/export-logs.sh${NC}"
  echo -e "${GREEN}    ./scripts/check-nf-health.sh${NC}"
fi

echo ""
echo -e "${BLUE}[*] Useful commands:${NC}"
echo -e "${GREEN}    docker compose ps              # View container status${NC}"
echo -e "${GREEN}    docker logs 5g-core-nrf        # View NRF logs${NC}"
echo -e "${GREEN}    docker compose down            # Stop all containers${NC}"
echo -e "${GREEN}    ./scripts/check-nf-health.sh watch  # Monitor health${NC}"
echo ""
