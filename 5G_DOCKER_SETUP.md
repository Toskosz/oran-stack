# O-RAN Stack Setup Guide - 5G Core + Near-RT RIC + CU/DU Split

## Overview

This project deploys a complete O-RAN-compliant 5G network across **three Docker Compose stacks** totaling ~27 containers:

| Stack | Compose File | Network | Containers |
|-------|-------------|---------|------------|
| **5G Core** | `docker-compose.yml` | `5g-core-network` (172.20.0.0/24) | 18 (17 NFs + MongoDB + WebUI) |
| **Near-RT RIC** | `docker-compose.ric.yml` | `ric-network` (172.22.0.0/24) | 6 (e2term, e2mgr, submgr, rtmgr, dbaas, a1mediator) |
| **CU/DU + UE** | `docker-compose.cudu.yml` | `ran-network` (172.21.0.0/24) | 3 (srs_cu, srs_du, srsue_5g_zmq) |

### Architecture Diagram

```
                       ric-network (172.22.0.0/24)
                 ┌──────────────────────────────────────┐
                 │  Near-RT RIC (O-RAN SC)              │
                 │  ric-dbaas     (172.22.0.214)        │
                 │  ric-e2term    (172.22.0.210) :36421 │
                 │  ric-e2mgr     (172.22.0.211)        │
                 │  ric-submgr    (172.22.0.212)        │
                 │  ric-rtmgr     (172.22.0.213)        │
                 │  ric-a1mediator(172.22.0.215)        │
                 └────────┬─────────────────────────────┘
                          │ E2 (SCTP :36421)
                          │ DU_RIC_IP=172.22.0.51
                          │
       ran-network (172.21.0.0/24)
  ┌───────────────────────┴────────────────────────────┐
  │  srs_cu   (172.21.0.50)  <── F1 ──>  srs_du (172.21.0.51)  │
  │                                       srsue  (172.21.0.34)  │
  │                                       (ZMQ virtual radio)   │
  └───────┬────────────────────────────────────────────┘
          │ N2/NG-U (SCTP :38412, GTP :2152)
          │ CU_CORE_IP=172.20.0.50
          │
       5g-core-network (172.20.0.0/24)
  ┌───────┴──────────────────────────────────────────────────┐
  │  5G Core (Open5GS)           │  4G/Legacy NFs            │
  │  NRF  (172.20.0.10)         │  MME  (172.20.0.2)        │
  │  SCP  (172.20.0.200)        │  SGW-C (172.20.0.3)       │
  │  SEPP (172.20.0.250)        │  SGW-U (172.20.0.6)       │
  │  AMF  (172.20.0.5)          │  HSS  (172.20.0.8)        │
  │  SMF  (172.20.0.4)          │  PCRF (172.20.0.21)       │
  │  UPF  (172.20.0.7)          │                            │
  │  AUSF (172.20.0.11)         │  Infrastructure            │
  │  UDM  (172.20.0.12)         │  MongoDB (172.20.0.254)    │
  │  PCF  (172.20.0.13)         │  WebUI  (172.20.0.16)     │
  │  NSSF (172.20.0.14)         │                            │
  │  BSF  (172.20.0.15)         │                            │
  │  UDR  (172.20.0.20)         │                            │
  └──────────────────────────────────────────────────────────┘
```

**Multi-homed containers** bridge the stacks:
- **srs_cu** connects to both `ran-network` (172.21.0.50) and `5g-core-network` (172.20.0.50) for N2/NG-U to AMF.
- **srs_du** connects to both `ran-network` (172.21.0.51) and `ric-network` (172.22.0.51) for E2 to e2term.

---

## Quick Start

### 1. Set Up Host TUN Interfaces

```bash
sudo ./setup-host-tun.sh
```

### 2. Build srsRAN Images (first time only)

```bash
docker build -f Dockerfile.srsran -t srsran-split:latest .
docker build -f Dockerfile.srsue -t srsue:latest .
```

### 3. Launch All Stacks

```bash
# Start everything (core -> RIC -> CU/DU + UE)
./launch-all.sh

# Or start with options:
./launch-all.sh --core-only    # Only 5G core
./launch-all.sh --no-ue        # Skip UE container
```

### 4. Verify Deployment

```bash
# Quick status across all stacks
./launch-all.sh --status

# Detailed health report
./scripts/check-nf-health.sh

# Continuous monitoring
./scripts/check-nf-health.sh watch
```

### 5. Shut Down

```bash
./launch-all.sh --down
```

---

## Detailed Setup Instructions

### Prerequisites

- Docker Engine 20.10+ (with Docker Compose)
- Linux host with TUN/TAP support
- Sufficient disk space (~15GB for all container images + MongoDB)
- Root/sudo access for TUN interface creation
- ~16GB RAM recommended (8GB minimum)

### Step 1: Create Host TUN Interfaces

```bash
sudo ./setup-host-tun.sh
```

This creates:
- `ogstun` - Primary TUN interface (10.45.0.1/16)
- `ogstun2` - Secondary TUN interface (10.46.0.1/16)
- `ogstun3` - Tertiary TUN interface (10.47.0.1/16)

**Note**: TUN interfaces are lost after reboot. For persistence, add to your system network manager.

### Step 2: Build Docker Images

```bash
# Build the 5G core image (if not already built)
docker build -f Dockerfile.5gscore -t teste-core:latest .

# Build srsRAN CU/DU image (multi-stage, clones from GitHub)
docker build -f Dockerfile.srsran -t srsran-split:latest .

# Build srsUE image (multi-stage, clones srsRAN_4G)
docker build -f Dockerfile.srsue -t srsue:latest .

# Build WebUI image
docker-compose build 5g-core-webui
```

### Step 3: Start the Deployment

```bash
# Recommended: use the orchestration script
./launch-all.sh

# Or start stacks individually:
docker-compose up -d                                                    # Core
docker-compose -f docker-compose.ric.yml up -d                         # RIC
docker-compose -f docker-compose.cudu.yml up -d                        # CU/DU + UE
```

### Step 4: Verify Deployment

```bash
# Check all containers
./launch-all.sh --status

# View logs across stacks
./launch-all.sh --logs

# Health check
./scripts/check-nf-health.sh
```

---

## Network Architecture

### Three Docker Bridge Networks

| Network | Subnet | Purpose |
|---------|--------|---------|
| `5g-core-network` | 172.20.0.0/24 | Core NF SBI + N2/N3/N4 interfaces |
| `ran-network` | 172.21.0.0/24 | F1 (CU-DU) + ZMQ virtual radio (DU-UE) |
| `ric-network` | 172.22.0.0/24 | RIC platform (E2, A1, internal RMR) |

### Cross-Network Connectivity

Multi-homed containers bridge the isolated networks:

```
5g-core-network          ran-network              ric-network
 172.20.0.0/24           172.21.0.0/24            172.22.0.0/24
      |                       |                        |
      |   CU_CORE_IP         |   CU_RAN_IP            |
      +--- 172.20.0.50 ------+--- 172.21.0.50         |
      |                       |                        |
      |                       |   DU_RAN_IP            |   DU_RIC_IP
      |                       +--- 172.21.0.51 --------+--- 172.22.0.51
      |                       |                        |
```

### 5G Core NF IP Allocations

| NF | Container | IP Address | SBI Port | Other Ports |
|---|---|---|---|---|
| NRF | 5g-core-nrf | 172.20.0.10 | 7777 | - |
| SCP | 5g-core-scp | 172.20.0.200 | 7777 | - |
| SEPP | 5g-core-sepp | 172.20.0.250 | 7777 | - |
| AMF | 5g-core-amf | 172.20.0.5 | 7777 | NGAP (38412) |
| SMF | 5g-core-smf | 172.20.0.4 | 7777 | GTP (2123/2152), PFCP (8805) |
| UPF | 5g-core-upf | 172.20.0.7 | - | GTP (2152), PFCP (8805) |
| AUSF | 5g-core-ausf | 172.20.0.11 | 7777 | - |
| UDM | 5g-core-udm | 172.20.0.12 | 7777 | - |
| PCF | 5g-core-pcf | 172.20.0.13 | 7777 | - |
| NSSF | 5g-core-nssf | 172.20.0.14 | 7777 | - |
| BSF | 5g-core-bsf | 172.20.0.15 | 7777 | - |
| UDR | 5g-core-udr | 172.20.0.20 | 7777 | - |
| MME | 5g-core-mme | 172.20.0.2 | - | GTP (2123), S1AP (36412) |
| SGW-C | 5g-core-sgwc | 172.20.0.3 | - | GTP (2123), PFCP (8805) |
| SGW-U | 5g-core-sgwu | 172.20.0.6 | - | GTP (2152), PFCP (8805) |
| HSS | 5g-core-hss | 172.20.0.1 | - | - |
| PCRF | 5g-core-pcrf | 172.20.0.21 | - | - |
| MongoDB | 5g-mongodb | 172.20.0.254 | 27017 | - |
| WebUI | 5g-core-webui | 172.20.0.16 | 9999 | - |

### Near-RT RIC IP Allocations

| Component | Container | IP Address | Key Ports |
|-----------|-----------|-----------|-----------|
| DBAAS (Redis) | ric-dbaas | 172.22.0.214 | 6379 |
| E2 Termination | ric-e2term | 172.22.0.210 | 36421 (SCTP), 38000 (RMR) |
| E2 Manager | ric-e2mgr | 172.22.0.211 | 3800 (HTTP), 38010 (RMR) |
| Subscription Mgr | ric-submgr | 172.22.0.212 | 3800 (HTTP), 38010 (RMR) |
| Routing Manager | ric-rtmgr | 172.22.0.213 | 3800 (HTTP) |
| A1 Mediator | ric-a1mediator | 172.22.0.215 | 10000 (HTTP) |

### CU/DU + UE IP Allocations

| Component | Container | Network(s) | IP Address(es) |
|-----------|-----------|-----------|----------------|
| CU (Central Unit) | srs_cu | ran + core | 172.21.0.50, 172.20.0.50 |
| DU (Distributed Unit) | srs_du | ran + ric | 172.21.0.51, 172.22.0.51 |
| UE (User Equipment) | srsue_5g_zmq | ran | 172.21.0.34 |

---

## Startup Order

### 5G Core (docker-compose.yml)

```
MongoDB (health check) -> NRF -> SCP -> SEPP -> AMF -> SMF -> UPF
-> AUSF -> UDM -> PCF -> NSSF -> BSF -> UDR -> MME -> SGW-C -> SGW-U -> HSS -> PCRF
```

### RIC (docker-compose.ric.yml)

```
ric-dbaas (Redis) -> ric-e2term -> ric-e2mgr -> ric-submgr -> ric-rtmgr -> ric-a1mediator
```

### CU/DU (docker-compose.cudu.yml)

```
srs_cu -> srs_du -> srsue_5g_zmq
```

The `launch-all.sh` script orchestrates all three stacks in order.

---

## Container Management

### View Container Status

```bash
# All stacks
./launch-all.sh --status

# Individual stacks
docker-compose ps
docker-compose -f docker-compose.ric.yml ps
docker-compose -f docker-compose.cudu.yml ps
```

### View Container Logs

```bash
# Follow a specific container
docker logs -f 5g-core-amf
docker logs -f ric-e2term
docker logs -f srs_cu

# All logs from one stack
docker-compose logs -f
docker-compose -f docker-compose.ric.yml logs -f
docker-compose -f docker-compose.cudu.yml logs -f

# Cross-stack logs via orchestrator
./launch-all.sh --logs
```

### Stop/Restart Containers

```bash
# Stop everything
./launch-all.sh --down

# Or individually
docker-compose down
docker-compose -f docker-compose.ric.yml down
docker-compose -f docker-compose.cudu.yml down

# Restart a specific container
docker-compose restart 5g-core-amf
docker-compose -f docker-compose.ric.yml restart ric-e2term
docker-compose -f docker-compose.cudu.yml restart srs_du
```

---

## Monitoring and Logging

### Health Check Script

```bash
# One-time health report (all 3 stacks)
./scripts/check-nf-health.sh

# Continuous monitoring
./scripts/check-nf-health.sh watch
```

The health script checks:
- All core containers (18)
- All RIC containers (6)
- All RAN containers (3)
- Docker network connectivity
- Redis (DBAAS) availability

### Log Export

```bash
./scripts/export-logs.sh
```

Exports per-container logs to `logs/` with timestamps.

---

## Key Interfaces

### N2 (AMF <-> CU)

The CU connects to AMF via the N2/NGAP interface:
- AMF listens on `172.20.0.5:38412` (SCTP)
- CU connects from `172.20.0.50` (its core-network IP)

### F1 (CU <-> DU)

F1 runs on `ran-network`:
- CU: `172.21.0.50:2153`
- DU: `172.21.0.51`

### E2 (DU -> RIC)

E2 runs between DU and e2term:
- e2term listens on `172.22.0.210:36421` (SCTP)
- DU connects from `172.22.0.51` (its ric-network IP)

### ZMQ Virtual Radio (DU <-> UE)

ZMQ sockets on `ran-network`:
- DU TX -> UE RX: `tcp://172.21.0.51:2000`
- UE TX -> DU RX: `tcp://172.21.0.34:2001`

---

## Subscriber Data

Two test subscribers are pre-loaded via `init-webui-data.js`:

| Field | 5G Subscriber | 4G Subscriber |
|-------|--------------|--------------|
| IMSI | 001010000000001 | 001010000000002 |
| K | 465B5CE8B199B49FAA5F0A2EE238A6BC | 465B5CE8B199B49FAA5F0A2EE238A6BC |
| OPc | E8ED289DEBA952E4283B54E88E6183CA | E8ED289DEBA952E4283B54E88E6183CA |
| APN | internet | internet |
| PLMN | 001/01 | 001/01 |

The srsUE configuration (`srsran/configs/ue.conf`) uses the 5G subscriber credentials.

### WebUI Access

```
URL: http://localhost:9999
Username: admin
Password: 1423
```

---

## MongoDB Access

```bash
# From host
mongosh mongodb://localhost:27017/open5gs

# From container
docker exec -it 5g-mongodb mongosh mongodb://localhost:27017/open5gs

# Check subscriber count
docker exec 5g-mongodb mongosh open5gs --eval "db.subscribers.countDocuments()"
```

---

## Troubleshooting

### Container Keeps Restarting

```bash
# Check logs for the failing container
docker logs 5g-core-nrf
docker logs ric-e2term
docker logs srs_cu
```

Common causes:
1. Image not built yet (`docker build -f Dockerfile.srsran ...`)
2. MongoDB not healthy (wait longer, check `docker logs 5g-mongodb`)
3. Dependent service not running (check startup order)

### CU Cannot Reach AMF

```bash
# Verify CU has core-network IP
docker exec srs_cu ip addr show
# Should show 172.20.0.50 on one interface

# Test connectivity
docker exec srs_cu ping 172.20.0.5
```

### DU Cannot Reach RIC

```bash
# Verify DU has ric-network IP
docker exec srs_du ip addr show
# Should show 172.22.0.51 on one interface

# Test connectivity
docker exec srs_du ping 172.22.0.210
```

### E2 Connection Failure

```bash
# Check e2term logs
docker logs ric-e2term

# Check Redis is up
docker exec ric-dbaas redis-cli ping
# Should return: PONG
```

### TUN Interface Issues

```bash
# Verify on host
ip tuntap list

# Recreate
sudo ./setup-host-tun.sh

# Verify in UPF container
docker exec 5g-core-upf ip addr show ogstun
```

### Network Connectivity Between Stacks

```bash
# Inspect Docker networks
docker network inspect 5g-core-network
docker network inspect ran-network
docker network inspect ric-network

# Verify multi-homed containers
docker inspect srs_cu --format '{{json .NetworkSettings.Networks}}' | python3 -m json.tool
docker inspect srs_du --format '{{json .NetworkSettings.Networks}}' | python3 -m json.tool
```

---

## Files and Structure

```
.
├── docker-compose.yml           # 5G Core (17 NFs + MongoDB + WebUI)
├── docker-compose.ric.yml       # Near-RT RIC (6 services)
├── docker-compose.cudu.yml      # CU/DU Split + UE (3 services)
├── Dockerfile.5gscore           # Open5GS build image
├── Dockerfile.webui             # Open5GS WebUI image
├── Dockerfile.srsran            # srsRAN CU/DU build (multi-stage)
├── Dockerfile.srsue             # srsRAN 4G UE build (multi-stage)
├── .env                         # All IP/port/PLMN configuration
├── entrypoint.sh                # Container initialization script
├── init-mongodb.js              # MongoDB replica set setup
├── init-webui-data.js           # Subscriber + admin initialization
├── setup-host-tun.sh            # TUN interface creation
├── launch-all.sh                # Multi-stack orchestration script
├── launch-5g-core.sh            # Legacy core-only launcher
├── srsran/
│   ├── configs/
│   │   ├── cu.yml               # CU configuration (N2, F1)
│   │   ├── du.yml               # DU configuration (F1, E2, ZMQ, cell)
│   │   └── ue.conf              # UE configuration (ZMQ, IMSI, keys)
│   └── logs/                    # srsRAN runtime logs
├── ric/
│   └── config/
│       ├── e2term/              # E2 termination config + routes
│       ├── e2mgr/               # E2 manager config + routes
│       ├── submgr/              # Subscription manager config + routes
│       ├── rtmgr/               # Routing manager config
│       └── a1mediator/          # A1 mediator config
├── configs/                     # Open5GS NF YAML templates
├── scripts/
│   ├── export-logs.sh           # Log export utility
│   └── check-nf-health.sh      # Health monitoring (all 3 stacks)
├── logs/                        # Runtime logs (auto-generated)
├── cu-du-split-report.md        # CU/DU split research report
└── docs (*.md)                  # Documentation files
```

---

## Environment Variables

Key variables in `.env`:

```bash
# PLMN
MCC=001
MNC=01

# Core network
DOCKER_SUBNET=172.20.0.0/24

# RAN network
RAN_SUBNET=172.21.0.0/24
CU_RAN_IP=172.21.0.50
CU_CORE_IP=172.20.0.50
DU_RAN_IP=172.21.0.51
DU_RIC_IP=172.22.0.51
UE_IP=172.21.0.34

# RIC network
RIC_SUBNET=172.22.0.0/24
RIC_E2TERM_IP=172.22.0.210

# srsRAN radio (ZMQ)
SRSRAN_DL_ARFCN=368500
SRSRAN_BAND=3
SRSRAN_BW_MHZ=20
```

---

## Next Steps

1. **Deploy and validate E2 connectivity**: Check `docker logs ric-e2term` for SCTP association from DU
2. **Test UE attachment**: Check `docker logs srs_cu` and `docker logs 5g-core-amf` for NAS registration
3. **Develop xApps**: Build O-RAN SC xApps that connect to the RIC via RMR messaging
4. **Scale to hardware**: Replace ZMQ virtual radio with USRP/SDR for over-the-air testing
5. **Kubernetes migration**: Convert compose files to Helm charts for production orchestration
