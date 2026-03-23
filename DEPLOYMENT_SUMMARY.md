# O-RAN Stack - Implementation Summary

## Completed Implementation

A full O-RAN-compliant 5G network deployed across three Docker Compose stacks: 5G Core (Open5GS), Near-RT RIC (O-RAN SC), and CU/DU Split with UE (srsRAN). Total: ~27 containers on 3 isolated Docker bridge networks.

---

## Containers Deployed

### Stack 1: 5G Core (`docker-compose.yml`) - 5g-core-network (172.20.0.0/24)

**5G NFs (3GPP Release 15+):**
1. NRF (Network Repository Function) - 172.20.0.10
2. SCP (Service Communication Proxy) - 172.20.0.200
3. SEPP (Security Edge Protection Proxy) - 172.20.0.250
4. AMF (Access and Mobility Function) - 172.20.0.5
5. SMF (Session Management Function) - 172.20.0.4
6. UPF (User Plane Function) - 172.20.0.7
7. AUSF (Authentication Server Function) - 172.20.0.11
8. UDM (Unified Data Management) - 172.20.0.12
9. PCF (Policy Control Function) - 172.20.0.13
10. NSSF (Network Slice Selection Function) - 172.20.0.14
11. BSF (Binding Support Function) - 172.20.0.15
12. UDR (Unified Data Repository) - 172.20.0.20

**4G/Legacy NFs:**
13. MME (Mobility Management Entity) - 172.20.0.2
14. SGW-C (Serving Gateway - Control Plane) - 172.20.0.3
15. SGW-U (Serving Gateway - User Plane) - 172.20.0.6
16. HSS (Home Subscriber Server) - 172.20.0.1
17. PCRF (Policy and Charging Rules Function) - 172.20.0.21

**Infrastructure:**
18. MongoDB - 172.20.0.254
19. WebUI - 172.20.0.16

### Stack 2: Near-RT RIC (`docker-compose.ric.yml`) - ric-network (172.22.0.0/24)

20. ric-dbaas (Redis) - 172.22.0.214
21. ric-e2term (E2 Termination) - 172.22.0.210
22. ric-e2mgr (E2 Manager) - 172.22.0.211
23. ric-submgr (Subscription Manager) - 172.22.0.212
24. ric-rtmgr (Routing Manager) - 172.22.0.213
25. ric-a1mediator (A1 Mediator) - 172.22.0.215

### Stack 3: CU/DU + UE (`docker-compose.cudu.yml`) - ran-network (172.21.0.0/24)

26. srs_cu (Central Unit) - 172.21.0.50 + 172.20.0.50 (multi-homed)
27. srs_du (Distributed Unit) - 172.21.0.51 + 172.22.0.51 (multi-homed)
28. srsue_5g_zmq (User Equipment) - 172.21.0.34

---

## Key Features Implemented

**Multi-Stack Architecture**
- Three isolated Docker bridge networks interconnected via multi-homed containers
- Core subnet narrowed from /16 to /24 to avoid overlap
- Cross-compose network referencing via `name:` + `external: true`

**Near-RT RIC (O-RAN SC)**
- Pre-built images from `nexus3.o-ran-sc.org:10001`
- RMR-based inter-component messaging with static routing tables
- E2 termination accepting SCTP connections from DU
- A1 mediator for policy management

**CU/DU Split (srsRAN)**
- Multi-stage Dockerfiles cloning from GitHub (no local clone needed)
- F1 interface between CU and DU on ran-network
- E2 interface from DU to RIC e2term
- N2/NG-U from CU to core AMF
- ZMQ virtual radio between DU and UE

**Subscriber Data**
- PLMN 001/01 throughout (IMSI prefix 00101)
- K: 465B5CE8B199B49FAA5F0A2EE238A6BC
- OPc: E8ED289DEBA952E4283B54E88E6183CA
- Matching credentials in init-webui-data.js and ue.conf

**Orchestration**
- `launch-all.sh` manages all three stacks with startup ordering
- Options: `--core-only`, `--no-ue`, `--down`, `--status`, `--logs`
- `check-nf-health.sh` monitors all 27+ containers across stacks

---

## Files Modified/Created

### Modified Files
1. **docker-compose.yml** - Subnet changed from /16 to /24, added `name: 5g-core-network`
2. **.env** - Added CU/DU/RIC IP variables, RAN/RIC network subnets, srsRAN radio params
3. **init-webui-data.js** - Fixed PLMN: IMSI 99970... -> 00101..., updated K/OPc keys
4. **scripts/check-nf-health.sh** - Extended to monitor RIC (6) + RAN (3) containers, Redis, networks

### Created Files
5. **docker-compose.ric.yml** - RIC stack: 6 services on ric-network
6. **docker-compose.cudu.yml** - CU/DU + UE: 3 services, multi-homed networking
7. **Dockerfile.srsran** - Multi-stage build for srsRAN_Project (CU/DU)
8. **Dockerfile.srsue** - Multi-stage build for srsRAN_4G (UE)
9. **launch-all.sh** - Multi-stack orchestration script
10. **srsran/configs/cu.yml** - CU config (N2 -> AMF, F1 -> DU)
11. **srsran/configs/du.yml** - DU config (F1 -> CU, E2 -> RIC, ZMQ, cell_cfg)
12. **srsran/configs/ue.conf** - UE config (ZMQ radio, IMSI, security keys)
13. **ric/config/e2term/** - E2 termination config + RMR routing
14. **ric/config/e2mgr/** - E2 manager config + RMR routing
15. **ric/config/submgr/** - Subscription manager config + RMR routing
16. **ric/config/rtmgr/** - Routing manager config
17. **ric/config/a1mediator/** - A1 mediator config

---

## Architecture Summary

```
┌─────────────────────┐    ┌─────────────────────┐    ┌─────────────────────┐
│   5G Core (Open5GS) │    │  Near-RT RIC (ORAN)  │    │  CU/DU + UE (srsRAN)│
│  docker-compose.yml │    │  compose.ric.yml     │    │  compose.cudu.yml   │
│                     │    │                      │    │                     │
│  5g-core-network    │    │  ric-network         │    │  ran-network        │
│  172.20.0.0/24      │    │  172.22.0.0/24       │    │  172.21.0.0/24      │
│                     │    │                      │    │                     │
│  17 NFs + MongoDB   │    │  e2term, e2mgr,      │    │  srs_cu, srs_du,    │
│  + WebUI            │    │  submgr, rtmgr,      │    │  srsue_5g_zmq       │
│                     │    │  dbaas, a1mediator   │    │                     │
└────────┬────────────┘    └──────────┬───────────┘    └──────┬──────────────┘
         │                            │                       │
         │  N2/NG-U                   │  E2                   │  F1 + ZMQ
         │  (CU_CORE_IP)             │  (DU_RIC_IP)          │
         └──────── srs_cu ───────────┘───── srs_du ──────────┘
```

---

## Quick Start

### 1. Create TUN Interfaces on Host
```bash
sudo ./setup-host-tun.sh
```

### 2. Build Images
```bash
docker build -f Dockerfile.srsran -t srsran-split:latest .
docker build -f Dockerfile.srsue -t srsue:latest .
```

### 3. Launch All Stacks
```bash
./launch-all.sh
```

### 4. Monitor Health
```bash
./scripts/check-nf-health.sh watch
```

### 5. Shut Down
```bash
./launch-all.sh --down
```

---

## Common Operations

### Start/Stop
```bash
./launch-all.sh              # Start all
./launch-all.sh --down       # Stop all
./launch-all.sh --status     # Check status
./launch-all.sh --logs       # View logs
./launch-all.sh --core-only  # Core only
```

### Access Container Shell
```bash
docker exec -it 5g-core-amf bash
docker exec -it ric-e2term bash
docker exec -it srs_cu bash
```

### View Logs
```bash
docker logs -f srs_cu
docker logs -f ric-e2term
docker-compose logs -f
```

### Check RIC
```bash
# E2 manager nodeb list
docker exec ric-e2mgr curl -s http://localhost:3800/v1/nodeb/states | python3 -m json.tool

# Redis health
docker exec ric-dbaas redis-cli ping
```

### Check MongoDB
```bash
docker exec 5g-mongodb mongosh open5gs --eval "db.subscribers.countDocuments()"
```

---

## Improvements Over Original Setup

| Feature | Before | After |
|---------|--------|-------|
| NF Containers | 17 core only | 27+ (core + RIC + CU/DU + UE) |
| RAN Support | None | srsRAN CU/DU split with F1 |
| RIC | None | O-RAN SC Near-RT RIC (6 components) |
| Networks | Single (172.20.0.0/16) | Three isolated /24 networks |
| Subscriber PLMN | 999/70 (mismatched) | 001/01 (consistent everywhere) |
| UE Testing | Manual external | Built-in srsUE with ZMQ radio |
| Orchestration | `docker-compose up -d` | `launch-all.sh` (multi-stack) |
| Health Monitoring | Core only | All 3 stacks + Redis + networks |

---

## Next Steps

1. Validate E2 SCTP association between DU and e2term
2. Test end-to-end UE registration through CU -> AMF
3. Develop xApps for the Near-RT RIC
4. Replace ZMQ with SDR hardware for over-the-air testing
5. Migrate to Kubernetes with Helm charts
