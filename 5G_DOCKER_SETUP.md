# 5G Core Docker Compose Setup Guide - Multi-NF Deployment

## Overview

This setup creates a fully containerized 5G core network with all 17 Network Functions (NFs) running in separate Docker containers, closely matching a real production deployment.

### Architecture Summary

```
┌──────────────────────────────────────────────────────────────────────────┐
│                          5G Core Docker Network                          │
│                      (Internal: 172.20.0.0/16)                           │
├──────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  5G Core NFs (3GPP Release 15+)          │  4G/Legacy NFs              │
│  ─────────────────────────────────────  │  ─────────────────────     │
│  1. NRF (172.20.0.10)                   │  13. MME (172.20.0.2)      │
│  2. SCP (172.20.0.200)                  │  14. SGW-C (172.20.0.3)    │
│  3. SEPP (172.20.0.250)                 │  15. SGW-U (172.20.0.6)    │
│  4. AMF (172.20.0.5)                    │  16. HSS (172.20.0.1)      │
│  5. SMF (172.20.0.4)                    │  17. PCRF (172.20.0.21)    │
│  6. UPF (172.20.0.7)                    │                             │
│  7. AUSF (172.20.0.11)                  │                             │
│  8. UDM (172.20.0.12)                   │                             │
│  9. PCF (172.20.0.13)                   │                             │
│  10. NSSF (172.20.0.14)                 │                             │
│  11. BSF (172.20.0.15)                  │                             │
│  12. UDR (172.20.0.20)                  │                             │
│                                                                          │
│  ┌──────────────────────────────────────────────────────────────┐      │
│  │                    MongoDB (172.20.0.254)                    │      │
│  │              (Shared database for all NFs)                  │      │
│  └──────────────────────────────────────────────────────────────┘      │
│                                                                          │
└──────────────────────────────────────────────────────────────────────────┘
```

## Quick Start (3 Steps)

### 1. Set Up Host TUN Interfaces

```bash
# Create TUN interfaces on the host (required for data plane)
sudo ./setup-host-tun.sh
```

### 2. Start All 5G Core Containers

```bash
# Option A: Simple start
docker-compose up -d

# Option B: Start with automatic log export
./launch-5g-core.sh logs
```

### 3. Verify All NFs are Running

```bash
# Check container status
docker-compose ps

# Or use the health check script
./scripts/check-nf-health.sh

# Or watch them in real-time
./scripts/check-nf-health.sh watch
```

**That's it!** All 17 NFs are now running and ready for testing.

---

## Detailed Setup Instructions

### Prerequisites

- Docker Engine 20.10+ (with Docker Compose)
- Linux host with TUN/TAP support
- Sufficient disk space (~10GB for MongoDB + container images)
- Root/sudo access for TUN interface creation

### Step 1: Create Host TUN Interfaces

The TUN interfaces must be created on the host and are shared with all containers:

```bash
sudo ./setup-host-tun.sh
```

This creates:
- `ogstun` - Primary TUN interface (10.45.0.1/16)
- `ogstun2` - Secondary TUN interface (10.46.0.1/16)
- `ogstun3` - Tertiary TUN interface (10.47.0.1/16)

**Note**: TUN interfaces are lost after reboot. For persistence, add to:
- Ubuntu/Debian: `/etc/network/interfaces`
- CentOS/RHEL: `/etc/sysconfig/network-scripts/`
- Or use your system's network manager

### Step 2: Start the Docker Compose Stack

Navigate to the project directory and start all containers:

```bash
docker-compose up -d
```

This will:
1. ✅ Start MongoDB and wait for it to be healthy
2. ✅ Start all 17 NF containers in the correct startup order
3. ✅ Initialize MongoDB replica set automatically
4. ✅ Create internal Docker network (172.20.0.0/16)
5. ✅ Mount TUN interfaces in all containers

### Step 3: Verify Deployment

Check that all containers are running:

```bash
# Quick status check
docker-compose ps

# Detailed health report
./scripts/check-nf-health.sh

# Watch health in real-time (updates every 5 seconds)
./scripts/check-nf-health.sh watch
```

### Step 4: Export and Archive Logs

Logs are automatically exported when using the launcher script:

```bash
./launch-5g-core.sh logs
```

Or manually export logs:

```bash
./scripts/export-logs.sh
```

This exports:
- Individual container logs: `logs/<container>_<timestamp>.log`
- Startup summary: `logs/startup_summary_<timestamp>.log`

---

## Network Architecture

### Internal Network (172.20.0.0/16)

All NF containers communicate via the Docker internal bridge network. This provides:

✅ **Isolation**: Network traffic is contained within Docker
✅ **Service Discovery**: Containers reach each other via service names
✅ **Production-like**: Matches typical 5G deployments
✅ **No Port Conflicts**: Multiple containers can use the same ports

### NF IP Allocations

| NF | Container | IP Address | SBI Port | Other Ports |
|---|---|---|---|---|
| NRF | 5g-core-nrf | 172.20.0.10 | 7777 | - |
| SCP | 5g-core-scp | 172.20.0.200 | 7777 | - |
| SEPP | 5g-core-sepp | 172.20.0.250 | 7777 | HTTPS (7777) |
| AMF | 5g-core-amf | 172.20.0.5 | 7777 | NGAP (38412), Metrics (9090) |
| SMF | 5g-core-smf | 172.20.0.4 | 7777 | GTP (2123/2152), PFCP (8805), Metrics (9090) |
| UPF | 5g-core-upf | 172.20.0.7 | - | GTP (2152), PFCP (8805), Metrics (9090) |
| AUSF | 5g-core-ausf | 172.20.0.11 | 7777 | - |
| UDM | 5g-core-udm | 172.20.0.12 | 7777 | - |
| PCF | 5g-core-pcf | 172.20.0.13 | 7777 | Metrics (9090) |
| NSSF | 5g-core-nssf | 172.20.0.14 | 7777 | - |
| BSF | 5g-core-bsf | 172.20.0.15 | 7777 | - |
| UDR | 5g-core-udr | 172.20.0.20 | 7777 | - |
| MME | 5g-core-mme | 172.20.0.2 | - | GTP (2123), S1AP (36412), Metrics (9090) |
| SGW-C | 5g-core-sgwc | 172.20.0.3 | - | GTP (2123), PFCP (8805) |
| SGW-U | 5g-core-sgwu | 172.20.0.6 | - | GTP (2152), PFCP (8805) |
| HSS | 5g-core-hss | 172.20.0.1 | - | MongoDB |
| PCRF | 5g-core-pcrf | 172.20.0.21 | - | MongoDB |
| MongoDB | 5g-mongodb | 172.20.0.254 | 27017 | - |

### Startup Order (Dependency Chain)

The containers start in this order to ensure proper NF registration and connectivity:

```
MongoDB (health check)
↓
NRF (service registry)
↓
SCP (service proxy)
↓
SEPP (security edge)
↓
AMF (access & mobility)
↓
SMF (session management)
↓
UPF (user plane)
↓
AUSF (authentication)
↓
UDM (subscriber data)
↓
PCF (policy control)
↓
NSSF (slice selection)
↓
BSF (binding support)
↓
UDR (unified data)
↓
MME (4G mobility)
↓
SGW-C (4G gateway control)
↓
SGW-U (4G gateway user)
↓
HSS (4G subscriber)
↓
PCRF (4G policy)
```

---

## Container Management

### View Container Status

```bash
# All containers
docker-compose ps

# Specific container
docker ps --filter "name=5g-core-nrf"

# Detailed inspection
docker inspect 5g-core-nrf
```

### View Container Logs

```bash
# View complete logs
docker logs 5g-core-nrf

# Follow logs in real-time (like `tail -f`)
docker logs -f 5g-core-nrf

# Last 50 lines
docker logs --tail 50 5g-core-nrf

# Logs with timestamps
docker logs --timestamps 5g-core-nrf
```

### Access Container Shell

```bash
# Interactive bash shell in NRF container
docker exec -it 5g-core-nrf bash

# Run specific commands
docker exec 5g-core-nrf ps aux
docker exec 5g-core-nrf ip addr show
```

### Stop/Restart Containers

```bash
# Stop all containers
docker-compose down

# Restart all containers
docker-compose restart

# Restart specific container
docker-compose restart 5g-core-nrf
docker restart 5g-core-nrf

# Remove stopped containers (careful!)
docker-compose rm
```

---

## Monitoring and Logging

### Automatic Log Export

Logs are automatically exported to the `logs/` directory:

```bash
logs/
├── 5g-core-nrf_20250319_120000.log
├── 5g-core-smf_20250319_120000.log
├── startup_summary_20250319_120000.log
└── ...
```

### Health Check Script

Monitor the health of all NFs:

```bash
# One-time health report
./scripts/check-nf-health.sh

# Continuous monitoring (refreshes every 5 seconds)
./scripts/check-nf-health.sh watch

# Stop watching with Ctrl+C
```

### Log Export Script

Manually export all logs:

```bash
./scripts/export-logs.sh
```

Generates:
- Individual container logs (in `logs/` directory)
- Startup summary with container status
- Network and MongoDB status information

### View Startup Summary

```bash
# Latest summary
cat logs/startup_summary_*.log | tail -1

# Or find by timestamp
ls -lt logs/startup_summary_*.log | head -1
```

### Docker Compose Logs

View logs from all containers:

```bash
# All container logs combined
docker-compose logs

# Follow all logs
docker-compose logs -f

# Specific service
docker-compose logs -f 5g-core-nrf

# Last 100 lines
docker-compose logs --tail 100
```

---

## MongoDB Access

### From Host

```bash
# Connect to MongoDB on host
mongosh mongodb://localhost:27017/open5gs

# Check replica set status
mongosh mongodb://localhost:27017 --eval 'rs.status()'

# List databases
mongosh mongodb://localhost:27017 --eval 'show dbs'
```

### From Container

```bash
# Connect from container
docker exec -it 5g-core-nrf mongosh mongodb://mongodb:27017/open5gs

# Check connection
docker exec 5g-core-mongodb mongosh --eval 'db.adminCommand("ping")'
```

### Database Operations

```bash
# List all databases
show dbs

# Use specific database
use open5gs

# List collections
show collections

# Count documents
db.subscribers.countDocuments()

# Find subscriber
db.subscribers.findOne()

# Insert test subscriber
db.subscribers.insertOne({name: "test"})
```

---

## Troubleshooting

### Container Keeps Restarting

**Symptom**: `docker-compose ps` shows containers restarting

**Check logs**:
```bash
docker logs 5g-core-nrf
```

**Common causes**:
1. Port already in use
2. MongoDB not healthy yet
3. NF executable not found

**Solution**:
```bash
# Stop and check logs
docker-compose down
docker-compose up -d
docker logs 5g-core-nrf
```

### MongoDB Connection Errors

**Symptom**: NF logs show `connection refused` or `MongoDB error`

**Check MongoDB is healthy**:
```bash
docker exec 5g-core-mongodb mongosh --eval 'db.adminCommand("ping")'
```

**Check connection from NF container**:
```bash
docker exec 5g-core-nrf mongosh mongodb://mongodb:27017/open5gs
```

**Solution**:
1. Ensure MongoDB container is running: `docker ps | grep mongodb`
2. Wait for MongoDB to be healthy: `docker-compose ps` (should show "healthy")
3. Check MongoDB logs: `docker logs 5g-core-mongodb`

### TUN Interface Issues

**Symptom**: `[WARN] Failed to create ogstun interface`

**Check TUN support on host**:
```bash
ip tuntap list
```

**Create TUN interfaces**:
```bash
sudo ./setup-host-tun.sh
```

**Verify in containers**:
```bash
docker exec 5g-core-upf ip addr show ogstun
```

### Network Connectivity Between NFs

**Test connectivity between containers**:
```bash
# From one container, ping another
docker exec 5g-core-nrf ping 172.20.0.4  # SMF IP

# Test specific port
docker exec 5g-core-nrf curl http://172.20.0.4:7777/
```

**Check Docker network**:
```bash
docker network inspect 5g-core-network
```

### Disk Space Issues

**Check available space**:
```bash
df -h

# Docker specific
docker system df
```

**Clean up old logs**:
```bash
rm -rf logs/*_*.log
```

**Remove unused containers/images**:
```bash
docker system prune -a
```

---

## Useful Commands Reference

```bash
# ============================================================================
# Container Management
# ============================================================================
docker-compose up -d                # Start all containers
docker-compose down                 # Stop all containers
docker-compose restart              # Restart all containers
docker-compose ps                   # View all container status
docker ps                          # View running containers
docker logs <container>             # View container logs
docker exec -it <container> bash    # Interactive shell in container

# ============================================================================
# Health & Monitoring
# ============================================================================
./scripts/check-nf-health.sh        # One-time health check
./scripts/check-nf-health.sh watch  # Continuous monitoring
./scripts/export-logs.sh            # Export all logs
./launch-5g-core.sh logs            # Start and export logs

# ============================================================================
# Network Inspection
# ============================================================================
docker network inspect 5g-core-network  # View Docker network
docker network ls                        # List all networks
docker ps --format "table {{.Names}}\t{{.Networks}}"  # Containers & networks

# ============================================================================
# MongoDB
# ============================================================================
docker exec -it 5g-core-mongodb mongosh mongodb://localhost:27017
docker exec 5g-core-mongodb mongosh --eval 'rs.status()'
mongosh mongodb://localhost:27017/open5gs

# ============================================================================
# Log Inspection
# ============================================================================
docker logs -f 5g-core-nrf              # Follow NRF logs
docker-compose logs -f                  # Follow all logs
ls -lah logs/                           # List exported logs
cat logs/startup_summary_*.log          # View startup summary

# ============================================================================
# Debugging
# ============================================================================
docker inspect 5g-core-nrf                      # Container details
docker stats                                    # Resource usage
docker exec 5g-core-nrf netstat -tlnp          # Open ports in container
docker exec 5g-core-nrf ps aux                 # Processes in container
docker exec 5g-core-nrf ip addr show           # IP addresses in container
```

---

## Files and Structure

```
.
├── docker-compose.yml           # 17 NF services + MongoDB
├── Dockerfile.5gscore           # Docker image for NFs
├── .env                         # IP allocations and configuration
├── entrypoint.sh                # Container initialization script
├── init-mongodb.js              # MongoDB replica set setup
├── setup-host-tun.sh            # TUN interface creation
├── launch-5g-core.sh            # Convenience launcher script
├── 5G_DOCKER_SETUP.md          # This file
├── scripts/
│   ├── export-logs.sh          # Log export and startup summary
│   └── check-nf-health.sh      # Health monitoring script
└── logs/                        # Output logs (created at runtime)
    ├── 5g-core-nrf_*.log
    ├── 5g-core-smf_*.log
    └── startup_summary_*.log
```

---

## Environment Variables

These can be overridden in `.env`:

```bash
# MongoDB
MONGODB_URI="mongodb://mongodb:27017/open5gs"

# Network
DOCKER_NETWORK="5g-core-network"
DOCKER_SUBNET="172.20.0.0/16"

# Logging
LOG_DIR="./logs"
LOG_TIMESTAMP=$(date +%Y%m%d_%H%M%S)
```

---

## Performance Tuning

### MongoDB Performance

For high throughput testing, adjust MongoDB:

```bash
docker exec -it 5g-core-mongodb mongosh --eval 'db.adminCommand({setParameter: 1, asyncLogBufferSize: 1024})'
```

### Container Resource Limits

To limit container resources, edit `docker-compose.yml`:

```yaml
5g-core-smf:
  resources:
    limits:
      cpus: '2'
      memory: 1G
    reservations:
      cpus: '1'
      memory: 512M
```

---

## Next Steps

### Testing the Deployment

1. **Verify all NFs are healthy**:
   ```bash
   ./scripts/check-nf-health.sh watch
   ```

2. **Access individual NFs**:
   ```bash
   docker exec -it 5g-core-smf bash
   ```

3. **Test inter-NF communication**:
   ```bash
   docker exec 5g-core-nrf curl http://172.20.0.4:7777/
   ```

4. **Run unit tests**:
   ```bash
   docker exec 5g-core-nrf bash -c "cd /open5gs && ./build/tests/unit/unit"
   ```

### Scaling to Kubernetes

The docker-compose setup is ready for Kubernetes migration:

1. Convert `docker-compose.yml` to Helm charts
2. Create ConfigMaps for Open5GS configurations
3. Deploy StatefulSet for MongoDB or use managed database
4. Create Deployments for each NF
5. Configure Services for inter-NF communication

---

## Support & Debugging

### Enable Debug Logging

Edit NF configuration files in container:

```bash
docker exec -it 5g-core-nrf bash
nano ./install/etc/open5gs/nrf.yaml
# Change log_level to DEBUG
# Exit container and restart
docker-compose restart 5g-core-nrf
```

### Check System Resources

```bash
# CPU and memory usage
docker stats

# Disk space
df -h

# Docker system info
docker system df
```

### Network Debugging

```bash
# Test connectivity between NFs
docker exec 5g-core-smf ping 172.20.0.10  # Ping NRF

# Check open ports in container
docker exec 5g-core-smf netstat -tlnp

# DNS resolution
docker exec 5g-core-smf nslookup mongodb
```

---

## Summary

This setup provides:

✅ **Complete 5G Core**: All 17 NFs in separate containers
✅ **Production-like**: Internal network (172.20.0.0/16), proper startup order
✅ **Easy Management**: Single `docker-compose up` command
✅ **Comprehensive Logging**: Automatic log export and health monitoring
✅ **Scalability**: Ready for Kubernetes migration
✅ **Troubleshooting**: Built-in health checks and monitoring scripts

For questions or issues, check the troubleshooting section or review container logs with `docker logs <container>`.
