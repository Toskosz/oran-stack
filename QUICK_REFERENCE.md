# O-RAN Stack - Quick Reference

## Start Everything

```bash
# 1. Create TUN interfaces on host (one-time, requires sudo)
sudo ./setup-host-tun.sh

# 2. Build srsRAN images (first time only)
docker build -f Dockerfile.srsran -t srsran-split:latest .
docker build -f Dockerfile.srsue -t srsue:latest .

# 3. Launch all 3 stacks (~27 containers)
./launch-all.sh

# 4. Monitor health
./scripts/check-nf-health.sh watch
```

---

## launch-all.sh Commands

```bash
./launch-all.sh              # Start all stacks (core -> RIC -> CU/DU + UE)
./launch-all.sh --down       # Stop all stacks
./launch-all.sh --status     # Show status of all containers
./launch-all.sh --logs       # Tail logs from all stacks
./launch-all.sh --core-only  # Start only the 5G core
./launch-all.sh --no-ue      # Start core + RIC + CU/DU (skip UE)
```

---

## Individual Stack Commands

```bash
# 5G Core
docker-compose up -d
docker-compose down
docker-compose ps
docker-compose logs -f

# Near-RT RIC
docker-compose -f docker-compose.ric.yml up -d
docker-compose -f docker-compose.ric.yml down
docker-compose -f docker-compose.ric.yml ps
docker-compose -f docker-compose.ric.yml logs -f

# CU/DU + UE
docker-compose -f docker-compose.cudu.yml up -d
docker-compose -f docker-compose.cudu.yml down
docker-compose -f docker-compose.cudu.yml ps
docker-compose -f docker-compose.cudu.yml logs -f
```

---

## Container List (All Stacks)

### 5G Core - 5g-core-network (172.20.0.0/24)

| # | NF | Container | IP | Port |
|---|-------|-------------|---------|------|
| 1 | NRF | 5g-core-nrf | 172.20.0.10 | 7777 |
| 2 | SCP | 5g-core-scp | 172.20.0.200 | 7777 |
| 3 | SEPP | 5g-core-sepp | 172.20.0.250 | 7777 |
| 4 | AMF | 5g-core-amf | 172.20.0.5 | 7777, 38412 |
| 5 | SMF | 5g-core-smf | 172.20.0.4 | 7777 |
| 6 | UPF | 5g-core-upf | 172.20.0.7 | 2152 |
| 7 | AUSF | 5g-core-ausf | 172.20.0.11 | 7777 |
| 8 | UDM | 5g-core-udm | 172.20.0.12 | 7777 |
| 9 | PCF | 5g-core-pcf | 172.20.0.13 | 7777 |
| 10 | NSSF | 5g-core-nssf | 172.20.0.14 | 7777 |
| 11 | BSF | 5g-core-bsf | 172.20.0.15 | 7777 |
| 12 | UDR | 5g-core-udr | 172.20.0.20 | 7777 |
| 13 | MME | 5g-core-mme | 172.20.0.2 | 2123 |
| 14 | SGW-C | 5g-core-sgwc | 172.20.0.3 | 2123 |
| 15 | SGW-U | 5g-core-sgwu | 172.20.0.6 | 2152 |
| 16 | HSS | 5g-core-hss | 172.20.0.1 | - |
| 17 | PCRF | 5g-core-pcrf | 172.20.0.21 | - |
| 18 | MongoDB | 5g-mongodb | 172.20.0.254 | 27017 |
| 19 | WebUI | 5g-core-webui | 172.20.0.16 | 9999 |

### Near-RT RIC - ric-network (172.22.0.0/24)

| # | Component | Container | IP | Port |
|---|-----------|-----------|---------|------|
| 20 | DBAAS | ric-dbaas | 172.22.0.214 | 6379 |
| 21 | E2 Term | ric-e2term | 172.22.0.210 | 36421 |
| 22 | E2 Mgr | ric-e2mgr | 172.22.0.211 | 3800 |
| 23 | Sub Mgr | ric-submgr | 172.22.0.212 | 3800 |
| 24 | Rt Mgr | ric-rtmgr | 172.22.0.213 | 3800 |
| 25 | A1 Med | ric-a1mediator | 172.22.0.215 | 10000 |

### CU/DU + UE - ran-network (172.21.0.0/24)

| # | Component | Container | IP(s) | Notes |
|---|-----------|-----------|-------|-------|
| 26 | CU | srs_cu | 172.21.0.50 + 172.20.0.50 | Multi-homed: ran + core |
| 27 | DU | srs_du | 172.21.0.51 + 172.22.0.51 | Multi-homed: ran + ric |
| 28 | UE | srsue_5g_zmq | 172.21.0.34 | ZMQ virtual radio |

---

## View Logs

```bash
# Core NFs
docker logs -f 5g-core-amf
docker logs -f 5g-core-smf
docker logs -f 5g-core-upf

# RIC components
docker logs -f ric-e2term
docker logs -f ric-e2mgr

# CU/DU/UE
docker logs -f srs_cu
docker logs -f srs_du
docker logs -f srsue_5g_zmq

# Export all logs to files
./scripts/export-logs.sh
```

---

## Check RIC Health

```bash
# Redis (DBAAS) ping
docker exec ric-dbaas redis-cli ping
# Expected: PONG

# E2 manager - list connected nodeBs
docker exec ric-e2mgr curl -s http://localhost:3800/v1/nodeb/states | python3 -m json.tool

# A1 mediator health
docker exec ric-a1mediator curl -s http://localhost:10000/a1-p/healthcheck
```

---

## Check CU/DU

```bash
# CU logs (look for N2 setup, F1 setup)
docker logs srs_cu 2>&1 | grep -i "ngap\|f1\|connected"

# DU logs (look for F1 setup, E2 setup, cell activation)
docker logs srs_du 2>&1 | grep -i "f1\|e2\|cell"

# UE logs (look for RRC connection, registration)
docker logs srsue_5g_zmq 2>&1 | grep -i "rrc\|attach\|register"
```

---

## MongoDB

```bash
# Connect
docker exec -it 5g-mongodb mongosh open5gs

# Count subscribers
docker exec 5g-mongodb mongosh open5gs --eval "db.subscribers.countDocuments()"

# View subscriber
docker exec 5g-mongodb mongosh open5gs --eval "db.subscribers.findOne()"
```

---

## WebUI

```
URL:      http://localhost:9999
Username: admin
Password: 1423
```

---

## Subscriber Data

```
IMSI:  001010000000001  (5G test subscriber)
K:     465B5CE8B199B49FAA5F0A2EE238A6BC
OPc:   E8ED289DEBA952E4283B54E88E6183CA
PLMN:  001/01
APN:   internet
```

---

## Network Debugging

```bash
# Inspect Docker networks
docker network inspect 5g-core-network
docker network inspect ran-network
docker network inspect ric-network

# Verify multi-homed CU (should show 2 networks)
docker inspect srs_cu --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}: {{$v.IPAddress}}{{"\n"}}{{end}}'

# Verify multi-homed DU
docker inspect srs_du --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}: {{$v.IPAddress}}{{"\n"}}{{end}}'

# Ping across stacks
docker exec srs_cu ping -c 1 172.20.0.5    # CU -> AMF (core-network)
docker exec srs_du ping -c 1 172.22.0.210  # DU -> e2term (ric-network)
docker exec srs_du ping -c 1 172.21.0.50   # DU -> CU (ran-network)
```

---

## Troubleshooting

### Containers not starting?
```bash
docker logs <container-name>           # Check specific container
./launch-all.sh --status              # Overview of all stacks
```

### CU can't reach AMF?
```bash
docker exec srs_cu ping 172.20.0.5    # Should succeed
docker inspect srs_cu | grep -A5 "5g-core-network"  # Verify network attachment
```

### E2 not connecting?
```bash
docker logs ric-e2term                 # Check for SCTP errors
docker exec ric-dbaas redis-cli ping   # Redis must be up first
```

### MongoDB issues?
```bash
docker logs 5g-mongodb                 # Check MongoDB logs
docker exec 5g-mongodb mongosh --eval 'db.adminCommand("ping")'
```

### TUN interfaces missing?
```bash
sudo ip tuntap list                    # Check on host
sudo ./setup-host-tun.sh              # Recreate
```

---

## File Structure

```
.
├── docker-compose.yml           # 5G Core (18 services)
├── docker-compose.ric.yml       # Near-RT RIC (6 services)
├── docker-compose.cudu.yml      # CU/DU + UE (3 services)
├── Dockerfile.5gscore           # Open5GS NF image
├── Dockerfile.webui             # WebUI image
├── Dockerfile.srsran            # srsRAN CU/DU image
├── Dockerfile.srsue             # srsRAN UE image
├── .env                         # All configuration
├── launch-all.sh                # Multi-stack orchestrator
├── srsran/configs/              # CU/DU/UE configs
│   ├── cu.yml
│   ├── du.yml
│   └── ue.conf
├── ric/config/                  # RIC component configs
│   ├── e2term/
│   ├── e2mgr/
│   ├── submgr/
│   ├── rtmgr/
│   └── a1mediator/
├── configs/                     # Open5GS NF templates
├── scripts/
│   ├── check-nf-health.sh      # Health monitor (all stacks)
│   └── export-logs.sh          # Log exporter
└── logs/                        # Runtime logs
```

---

## Full Documentation

See **5G_DOCKER_SETUP.md** for complete architecture, network diagrams, and detailed setup instructions.
