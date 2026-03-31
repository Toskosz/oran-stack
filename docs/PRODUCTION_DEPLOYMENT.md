# Production Deployment Guide - O-RAN Stack

**Last Updated**: March 2026
**Version**: 2.0 - Full O-RAN Stack (Core + RIC + CU/DU)

## Table of Contents

1. [Overview](#overview)
2. [System Requirements](#system-requirements)
3. [Quick Start](#quick-start)
4. [Detailed Setup](#detailed-setup)
5. [Image Build](#image-build)
6. [WebUI & Subscriber Management](#webui--subscriber-management)
7. [Data Plane Validation](#data-plane-validation)
8. [RIC Operations](#ric-operations)
9. [Troubleshooting](#troubleshooting)
10. [Production Considerations](#production-considerations)
11. [Monitoring and Logging](#monitoring-and-logging)
12. [Configuration Reference](#configuration-reference)

---

## Overview

This deployment provides a **complete O-RAN-compliant 5G network** with three Docker Compose stacks:

| Stack | Components | Compose File |
|-------|-----------|-------------|
| **5G Core** | Open5GS: 17 NFs + MongoDB + WebUI | `docker-compose.yml` |
| **Near-RT RIC** | O-RAN SC: e2term, e2mgr, submgr, rtmgr, dbaas, a1mediator | `docker-compose.ric.yml` |
| **CU/DU + UE** | srsRAN: CU, DU (split mode), UE (ZMQ radio) | `docker-compose.cudu.yml` |

### Key Features

- **Complete 5G & 4G Core**: All 17 Open5GS NFs with proper startup ordering
- **O-RAN Near-RT RIC**: E2 termination, subscription management, A1 policy, routing
- **CU/DU Split**: srsRAN Project with F1 interface, multi-homed networking
- **Built-in UE**: srsRAN 4G UE with ZMQ virtual radio for testing
- **Three Isolated Networks**: 5g-core-network, ran-network, ric-network
- **Consistent PLMN**: 001/01 across all components (core, CU, DU, UE)

---

## System Requirements

### Hardware
- **CPU**: 4+ cores (8+ recommended)
- **RAM**: 16GB recommended (8GB minimum)
- **Disk**: 50GB+ (SSD recommended) - images are ~10-15GB total
- **Network**: Host with internet access for builds and data plane

### Software
- **Linux**: Ubuntu 22.04 LTS recommended
- **Linux Kernel**: 5.0+ with TUN/TAP support
- **Docker**: 20.10+
- **Docker Compose**: 1.29+
- **Root Access**: Required for TUN setup

### Network Prerequisites
- TUN/TAP kernel module enabled
- No conflicting Docker networks on 172.20.0.0/24, 172.21.0.0/24, 172.22.0.0/24
- No existing iptables rules blocking Docker traffic

---

## Quick Start

### 1. Clone Repository
```bash
git clone https://github.com/Toskosz/oran-stack.git
cd oran-stack
```

### 2. Setup Host Network
```bash
sudo ./scripts/setup-host-tun.sh
sudo ./scripts/setup-host-network.sh
```

### 3. Build All Docker Images
```bash
# Core NF image
docker build -f dockerfiles/Dockerfile.5gscore -t teste-core:latest .

# WebUI image
docker-compose build 5g-core-webui

# srsRAN CU/DU image (multi-stage, ~15 min first time)
docker build -f dockerfiles/Dockerfile.srsran -t srsran-split:latest .

# srsRAN UE image (multi-stage, ~10 min first time)
docker build -f dockerfiles/Dockerfile.srsue -t srsue:latest .
```

### 4. Launch Everything
```bash
./scripts/launch-all.sh
```

### 5. Verify
```bash
./scripts/launch-all.sh --status
./scripts/check-nf-health.sh
```

### 6. Access WebUI
```
URL: http://localhost:9999
Username: admin
Password: 1423
```

---

## Detailed Setup

### Step 1: Verify Prerequisites

```bash
docker --version          # 20.10+
docker-compose --version  # 1.29+
sudo whoami               # root
nproc                     # 4+
free -h                   # 8GB+ available
```

### Step 2: Configure TUN Interfaces

```bash
sudo ./scripts/setup-host-tun.sh

# Verify
ip tuntap list
# Should show: ogstun, ogstun2, ogstun3
```

### Step 3: Configure Data Plane Networking

```bash
sudo ./scripts/setup-host-network.sh

# Verify
sysctl net.ipv4.ip_forward              # Should be 1
iptables -t nat -L -n | grep MASQUERADE  # Should show NAT rules
```

### Step 4: Customize Configuration (Optional)

Edit `.env`:
```bash
MCC=001          # Mobile Country Code
MNC=01           # Mobile Network Code
TAC=1            # Tracking Area Code
LOG_LEVEL=info   # debug, info, warning, error
```

### Step 5: Build Docker Images

See [Image Build](#image-build) section below.

### Step 6: Launch

```bash
# All stacks
./scripts/launch-all.sh

# Or selectively:
./scripts/launch-all.sh --core-only   # Core only
./scripts/launch-all.sh --no-ue       # Core + RIC + CU/DU (no UE)
```

### Step 7: Verify

```bash
./scripts/launch-all.sh --status
./scripts/check-nf-health.sh watch
```

---

## Image Build

Four Docker images need to be built:

### Core NF Image (teste-core)
```bash
docker build -f dockerfiles/Dockerfile.5gscore -t teste-core:latest .
# Time: ~10-15 minutes (first build)
# Used by: All 17 Open5GS NF containers
```

### WebUI Image
```bash
docker-compose build 5g-core-webui
# Time: ~5-10 minutes
# Used by: 5g-core-webui container
```

### srsRAN CU/DU Image (srsran-split)
```bash
docker build -f dockerfiles/Dockerfile.srsran -t srsran-split:latest .
# Time: ~15-20 minutes (clones srsRAN_Project from GitHub)
# Used by: srs_cu, srs_du containers
# Multi-stage build: builder -> runtime
```

### srsRAN UE Image (srsue)
```bash
docker build -f dockerfiles/Dockerfile.srsue -t srsue:latest .
# Time: ~10-15 minutes (clones srsRAN_4G from GitHub)
# Used by: srsue_5g_zmq container
# Multi-stage build: builder -> runtime
```

### RIC Images (Pre-built)
RIC containers use pre-built images from the O-RAN SC registry:
- `nexus3.o-ran-sc.org:10001/o-ran-sc/ric-plt-e2:6.0.8`
- `nexus3.o-ran-sc.org:10001/o-ran-sc/ric-plt-e2mgr:6.0.8`
- `nexus3.o-ran-sc.org:10001/o-ran-sc/ric-plt-submgr:0.10.4`
- `nexus3.o-ran-sc.org:10001/o-ran-sc/ric-plt-rtmgr:0.9.6`
- `nexus3.o-ran-sc.org:10001/o-ran-sc/ric-plt-a1:3.2.2`
- `redis:6-alpine` (DBAAS)

These are pulled automatically on first `docker-compose -f docker-compose.ric.yml up -d`.

---

## WebUI & Subscriber Management

### Access WebUI

```
URL: http://localhost:9999
Username: admin
Password: 1423
```

### Pre-loaded Subscribers

Two test subscribers are initialized via `init-webui-data.js`:

**5G Subscriber:**
| Field | Value |
|-------|-------|
| IMSI | 001010000000001 |
| K | 465B5CE8B199B49FAA5F0A2EE238A6BC |
| OPc | E8ED289DEBA952E4283B54E88E6183CA |
| APN | internet |
| SST | 1 (eMBB) |

**4G Subscriber:**
| Field | Value |
|-------|-------|
| IMSI | 001010000000002 |
| K | 465B5CE8B199B49FAA5F0A2EE238A6BC |
| OPc | E8ED289DEBA952E4283B54E88E6183CA |
| APN | internet |

The 5G subscriber credentials match `srsran/configs/ue.conf`.

### Add a New Subscriber

1. Login to WebUI at `http://localhost:9999`
2. Navigate to **Subscriber** in sidebar
3. Click **+** to add
4. Fill in:
   - IMSI: `001010000000003` (must start with 00101 for PLMN 001/01)
   - K and OPc: your chosen keys
   - APN: `internet`
   - SST: 1
5. Click **SAVE**

Update `srsran/configs/ue.conf` to match the new subscriber's credentials if you want the UE to use them.

---

## Data Plane Validation

### Verify UE Connectivity

```bash
# Check UE registration
docker logs srsue_5g_zmq 2>&1 | grep -i "register\|attach\|connected"

# Check AMF for accepted registration
docker logs 5g-core-amf 2>&1 | grep -i "registration.*accept"

# Check SMF for PDU session
docker logs 5g-core-smf 2>&1 | grep -i "pdu.*session"

# Check UPF for GTP tunnel
docker logs 5g-core-upf 2>&1 | grep -i "gtp.*session"
```

### Network Configuration Verification

```bash
# TUN interfaces
ip addr show dev ogstun  # 10.45.0.1/16

# IP forwarding
sysctl net.ipv4.ip_forward  # 1

# NAT rules
iptables -t nat -L -n | grep MASQUERADE

# Monitor UE traffic
tcpdump -i ogstun -nn icmp
```

---

## RIC Operations

### Check RIC Health

```bash
# Redis
docker exec ric-dbaas redis-cli ping

# E2 Manager API
docker exec ric-e2mgr curl -s http://localhost:3800/v1/nodeb/states | python3 -m json.tool

# A1 Mediator
docker exec ric-a1mediator curl -s http://localhost:10000/a1-p/healthcheck
```

### E2 Connection Status

```bash
# Check e2term for SCTP associations
docker logs ric-e2term 2>&1 | grep -i "sctp\|association\|connect"

# Check registered nodebs
docker exec ric-e2mgr curl -s http://localhost:3800/v1/nodeb/states
```

### A1 Policy Management

```bash
# List policy types
docker exec ric-a1mediator curl -s http://localhost:10000/a1-p/policytypes

# Health check
docker exec ric-a1mediator curl -s http://localhost:10000/a1-p/healthcheck
```

---

## Troubleshooting

### Docker Build Fails
```bash
# Check network access
docker run --rm curlimages/curl curl -I https://github.com

# Try no-cache rebuild
docker build --no-cache -f dockerfiles/Dockerfile.srsran -t srsran-split:latest .
```

### NFs Not Starting
```bash
docker logs 5g-core-nrf -f

# Common: TUN not created
sudo ./scripts/setup-host-tun.sh

# Common: MongoDB not ready
docker logs 5g-mongodb
```

### RIC Components Crashing
```bash
# Redis must be up first
docker logs ric-dbaas

# Restart RIC stack
docker-compose -f docker-compose.ric.yml down
docker-compose -f docker-compose.ric.yml up -d
```

### CU Can't Reach AMF
```bash
# Verify CU has core-network IP
docker inspect srs_cu --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}: {{$v.IPAddress}}{{"\n"}}{{end}}'

# Core network must exist before CU starts
docker network ls | grep 5g-core-network
```

### DU Can't Reach E2Term
```bash
# Verify DU has ric-network IP
docker inspect srs_du --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}: {{$v.IPAddress}}{{"\n"}}{{end}}'

# Test connectivity
docker exec srs_du ping -c 1 172.22.0.210
```

### WebUI Not Accessible
```bash
docker ps | grep webui
docker logs 5g-core-webui
docker port 5g-core-webui
```

### MongoDB Won't Start
```bash
docker logs 5g-mongodb
df -h /  # Check disk space

# Full reset (WARNING: deletes data)
docker-compose down -v
docker-compose up -d
```

---

## Production Considerations

### Security

1. **Change Default Credentials**: WebUI admin/1423
2. **Use Real Security Keys**: Replace test K/OPc with operator-generated keys
3. **Enable TLS**: Configure SBI TLS, E2 TLS, HTTPS for WebUI
4. **Network Isolation**: Restrict gNB access to AMF, restrict WebUI to management network
5. **Backup Strategy**: Regular MongoDB dumps

### Monitoring

```bash
# Prometheus metrics from Open5GS NFs (port 9090)
# AMF: http://172.20.0.5:9090/metrics
# SMF: http://172.20.0.4:9090/metrics
# UPF: http://172.20.0.7:9090/metrics

# Redis monitoring
docker exec ric-dbaas redis-cli info stats

# Container resource usage
docker stats --no-stream
```

### High Availability

1. **MongoDB**: Extend to 3-node replica set
2. **NF Redundancy**: Multiple AMF/SMF/UPF instances with NRF discovery
3. **RIC HA**: Multiple e2term instances behind load balancer
4. **Orchestration**: Migrate to Kubernetes with Helm charts

### Performance Tuning

```bash
ulimit -n 65536
sudo sysctl -w net.core.rmem_max=134217728
sudo sysctl -w net.core.wmem_max=134217728
```

---

## Monitoring and Logging

### View Logs

```bash
# Core
docker-compose logs -f
docker logs -f 5g-core-amf

# RIC
docker-compose -f docker-compose.ric.yml logs -f
docker logs -f ric-e2term

# CU/DU
docker-compose -f docker-compose.cudu.yml logs -f
docker logs -f srs_cu

# Export all
./scripts/export-logs.sh
```

### Health Checks

```bash
# All stacks
./scripts/check-nf-health.sh
./scripts/check-nf-health.sh watch

# Quick status
./scripts/launch-all.sh --status
```

### Common Log Patterns

**Successful NF Startup:**
```
[app] INFO: NRF initialize...done
[sbi] INFO: nghttp2_server() [http://172.20.0.10]:7777
```

**UE Registration:**
```
[gmm] INFO: Registration is accepted
```

**E2 Association:**
```
E2 setup request received from...
```

---

## Configuration Reference

### Environment Variables (.env)

Key groups:
- **PLMN**: MCC, MNC, TAC
- **Core Network**: DOCKER_SUBNET=172.20.0.0/24, NF IPs
- **RAN Network**: RAN_SUBNET=172.21.0.0/24, CU/DU IPs
- **RIC Network**: RIC_SUBNET=172.22.0.0/24, RIC component IPs
- **srsRAN Radio**: SRSRAN_DL_ARFCN, SRSRAN_BAND, SRSRAN_BW_MHZ

### Configuration Files

| File | Purpose |
|------|---------|
| `configs/*.yaml` | Open5GS NF templates (envsubst at runtime) |
| `srsran/configs/cu.yml` | CU: N2 -> AMF, F1 -> DU |
| `srsran/configs/du.yml` | DU: F1 -> CU, E2 -> RIC, ZMQ radio, cell config |
| `srsran/configs/ue.conf` | UE: ZMQ radio, IMSI, K, OPc |
| `ric/config/e2term/` | E2 termination config + RMR routes |
| `ric/config/e2mgr/` | E2 manager config + RMR routes |
| `ric/config/submgr/` | Subscription manager config + routes |
| `ric/config/rtmgr/` | Routing manager config |
| `ric/config/a1mediator/` | A1 mediator config |

### Docker Compose Files

| File | Services | Network |
|------|----------|---------|
| `docker-compose.yml` | 18+ (core NFs + MongoDB + WebUI) | 5g-core-network |
| `docker-compose.ric.yml` | 6 (RIC platform) | ric-network |
| `docker-compose.cudu.yml` | 3 (CU, DU, UE) | ran-network (+ cross-network) |

---

**Remember**: This is a lab/testing deployment. For production, conduct security audits, load testing, and disaster recovery planning.
