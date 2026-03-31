# Deployment Testing Guide - O-RAN Stack

**Purpose**: Step-by-step instructions to test the full O-RAN stack deployment (5G Core + Near-RT RIC + CU/DU Split + UE)
**Target Environment**: Linux (Ubuntu 22.04 LTS recommended)
**Estimated Duration**: 45-60 minutes for full test suite
**Difficulty Level**: Intermediate

---

## Table of Contents

1. [Pre-Deployment Checklist](#pre-deployment-checklist)
2. [Test Phase 1: Infrastructure Setup](#test-phase-1-infrastructure-setup)
3. [Test Phase 2: 5G Core Deployment](#test-phase-2-5g-core-deployment)
4. [Test Phase 3: Core NF Health & Connectivity](#test-phase-3-core-nf-health--connectivity)
5. [Test Phase 4: WebUI & Subscriber Data](#test-phase-4-webui--subscriber-data)
6. [Test Phase 5: Near-RT RIC Deployment](#test-phase-5-near-rt-ric-deployment)
7. [Test Phase 6: CU/DU + UE Deployment](#test-phase-6-cudu--ue-deployment)
8. [Test Phase 7: Interface Validation](#test-phase-7-interface-validation)
9. [Test Phase 8: End-to-End Validation](#test-phase-8-end-to-end-validation)
10. [Troubleshooting Test Failures](#troubleshooting-test-failures)
11. [Test Report Template](#test-report-template)

---

## Pre-Deployment Checklist

### Hardware Requirements
```bash
# Check CPU cores (need 4+, 8+ recommended)
nproc

# Check available RAM (need 8GB+, 16GB recommended)
free -h | grep Mem

# Check disk space (need 50GB+)
df -h /
```

### Software Requirements
```bash
# Docker Engine 20.10+
docker --version

# Docker Compose 1.29+
docker-compose --version

# TUN/TAP support
cat /proc/net/dev | grep -q tun && echo "TUN OK" || echo "TUN MISSING"
```

### Network Prerequisites
```bash
# No conflicts with our 3 subnets
ip route | grep -E "172\.20\.0|172\.21\.0|172\.22\.0" && echo "CONFLICT" || echo "No conflict"
```

### Image Build Verification
```bash
# Verify all required images exist
docker images | grep -E "(teste-core|srsran-split|srsue|open5gs-webui)" | wc -l
# Expected: 4 (or build them first)

# Build if needed:
# docker build -f dockerfiles/Dockerfile.5gscore -t teste-core:latest .
# docker build -f dockerfiles/Dockerfile.srsran -t srsran-split:latest .
# docker build -f dockerfiles/Dockerfile.srsue -t srsue:latest .
# docker-compose build 5g-core-webui
```

---

## Test Phase 1: Infrastructure Setup

### Test 1.1: Create TUN Interfaces
```bash
sudo ./scripts/setup-host-tun.sh

# Verify
ip link show | grep -E "ogstun[0-9]?"
# Expected: Three lines showing ogstun, ogstun2, ogstun3
```

**Pass Criteria**: All three TUN interfaces created

### Test 1.2: Verify TUN IP Addresses
```bash
ip -4 addr show ogstun   # Expected: 10.45.0.1/16
ip -4 addr show ogstun2  # Expected: 10.46.0.1/16
ip -4 addr show ogstun3  # Expected: 10.47.0.1/16
```

**Pass Criteria**: Correct IPs on all TUN interfaces

### Test 1.3: Verify Docker Networks Don't Exist Yet
```bash
docker network ls | grep -E "(5g-core-network|ran-network|ric-network)"
# Expected: No results (networks created by compose)
```

---

## Test Phase 2: 5G Core Deployment

### Test 2.1: Start Core Stack
```bash
docker-compose up -d

# Wait for startup
sleep 45
docker-compose ps
```

**Pass Criteria**: All 18+ containers show "Up" status

### Test 2.2: Verify Core Network
```bash
docker network inspect 5g-core-network | grep -E "Subnet|Name"
# Expected: Subnet 172.20.0.0/24, Name: 5g-core-network
```

**Pass Criteria**: Network exists with correct /24 subnet

### Test 2.3: MongoDB Health
```bash
docker exec 5g-mongodb mongosh --eval 'db.adminCommand("ping")'
# Expected: { ok: 1 }
```

**Pass Criteria**: MongoDB responds to ping

---

## Test Phase 3: Core NF Health & Connectivity

### Test 3.1: Check for Startup Errors
```bash
for nf in nrf scp amf smf upf ausf udm pcf nssf bsf udr; do
  echo "=== 5g-core-${nf} ==="
  docker logs 5g-core-${nf} 2>&1 | grep -i "error\|fatal" | head -3
done
```

**Pass Criteria**: No critical/fatal errors in NF logs

### Test 3.2: NRF Registration
```bash
docker exec 5g-core-amf curl -s http://172.20.0.10:7777/nnrf-nfm/v1/nf-instances | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('nfInstances',[])))" 2>/dev/null
# Expected: 10+ registered NFs
```

**Pass Criteria**: NRF shows registered NF instances

### Test 3.3: Inter-NF Connectivity
```bash
# SMF can reach NRF
docker exec 5g-core-smf ping -c 1 172.20.0.10
# Expected: 1 packet received

# AMF can reach UPF
docker exec 5g-core-amf ping -c 1 172.20.0.7
# Expected: 1 packet received
```

**Pass Criteria**: NFs can communicate on core network

### Test 3.4: Data Plane Setup
```bash
# UPF IP forwarding
docker exec 5g-core-upf sysctl net.ipv4.ip_forward
# Expected: net.ipv4.ip_forward = 1

# GTP-U listener
docker exec 5g-core-upf netstat -tuln | grep 2152
# Expected: 0.0.0.0:2152 LISTEN
```

**Pass Criteria**: UPF has IP forwarding and GTP-U listener

---

## Test Phase 4: WebUI & Subscriber Data

### Test 4.1: WebUI Accessible
```bash
curl -s -o /dev/null -w "%{http_code}" http://localhost:9999/
# Expected: 200
```

**Pass Criteria**: WebUI responds with HTTP 200

### Test 4.2: Subscriber Data Initialized
```bash
docker exec 5g-mongodb mongosh open5gs --eval "db.subscribers.countDocuments()"
# Expected: 2

docker exec 5g-mongodb mongosh open5gs --eval "db.subscribers.findOne({imsi:'001010000000001'}).imsi"
# Expected: 001010000000001
```

**Pass Criteria**: 2 subscribers with IMSI prefix 00101

### Test 4.3: Security Keys Match UE Config
```bash
docker exec 5g-mongodb mongosh open5gs --eval "db.auths.findOne({imsi:'001010000000001'}).k"
# Expected: 465B5CE8B199B49FAA5F0A2EE238A6BC
```

**Pass Criteria**: K key in MongoDB matches ue.conf

---

## Test Phase 5: Near-RT RIC Deployment

### Test 5.1: Start RIC Stack
```bash
docker-compose -f docker-compose.ric.yml up -d

# Wait for startup
sleep 30
docker-compose -f docker-compose.ric.yml ps
```

**Pass Criteria**: All 6 RIC containers show "Up" status

### Test 5.2: Verify RIC Network
```bash
docker network inspect ric-network | grep -E "Subnet|Name"
# Expected: Subnet 172.22.0.0/24, Name: ric-network
```

**Pass Criteria**: RIC network exists with correct /24 subnet

### Test 5.3: Redis (DBAAS) Health
```bash
docker exec ric-dbaas redis-cli ping
# Expected: PONG

docker exec ric-dbaas redis-cli info server | grep redis_version
# Expected: redis_version:6.x.x
```

**Pass Criteria**: Redis responds to PING

### Test 5.4: E2 Termination Ready
```bash
docker logs ric-e2term 2>&1 | grep -i "listening\|ready\|sctp\|started" | head -5
# Expected: Messages indicating SCTP listener is ready on port 36421
```

**Pass Criteria**: e2term is listening for E2 connections

### Test 5.5: E2 Manager Health
```bash
docker exec ric-e2mgr curl -s http://localhost:3800/v1/nodeb/states
# Expected: JSON response (may be empty array if no nodes connected yet)
```

**Pass Criteria**: E2 manager API responds

### Test 5.6: A1 Mediator Health
```bash
docker exec ric-a1mediator curl -s http://localhost:10000/a1-p/healthcheck
# Expected: 200 OK or healthy response
```

**Pass Criteria**: A1 mediator responds to health check

### Test 5.7: RIC Component Connectivity
```bash
# e2mgr can reach Redis
docker exec ric-e2mgr ping -c 1 172.22.0.214
# Expected: 1 packet received

# e2term can reach e2mgr
docker exec ric-e2term ping -c 1 172.22.0.211
# Expected: 1 packet received
```

**Pass Criteria**: RIC components can communicate on ric-network

---

## Test Phase 6: CU/DU + UE Deployment

### Test 6.1: Start CU/DU Stack
```bash
docker-compose -f docker-compose.cudu.yml up -d

# Wait for startup
sleep 20
docker-compose -f docker-compose.cudu.yml ps
```

**Pass Criteria**: All 3 containers (srs_cu, srs_du, srsue_5g_zmq) show "Up"

### Test 6.2: Verify RAN Network
```bash
docker network inspect ran-network | grep -E "Subnet|Name"
# Expected: Subnet 172.21.0.0/24, Name: ran-network
```

### Test 6.3: CU Multi-Homing
```bash
# CU should have IPs on both ran-network and 5g-core-network
docker inspect srs_cu --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}: {{$v.IPAddress}}{{"\n"}}{{end}}'
# Expected:
#   ran-network: 172.21.0.50
#   5g-core-network: 172.20.0.50
```

**Pass Criteria**: CU has IPs on both networks

### Test 6.4: DU Multi-Homing
```bash
docker inspect srs_du --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}: {{$v.IPAddress}}{{"\n"}}{{end}}'
# Expected:
#   ran-network: 172.21.0.51
#   ric-network: 172.22.0.51
```

**Pass Criteria**: DU has IPs on both networks

### Test 6.5: CU -> AMF Connectivity (N2 path)
```bash
docker exec srs_cu ping -c 1 172.20.0.5
# Expected: 1 packet received (CU can reach AMF on core network)
```

**Pass Criteria**: CU can reach AMF via core-network

### Test 6.6: DU -> CU Connectivity (F1 path)
```bash
docker exec srs_du ping -c 1 172.21.0.50
# Expected: 1 packet received (DU can reach CU on ran-network)
```

**Pass Criteria**: DU can reach CU via ran-network

### Test 6.7: DU -> E2Term Connectivity (E2 path)
```bash
docker exec srs_du ping -c 1 172.22.0.210
# Expected: 1 packet received (DU can reach e2term on ric-network)
```

**Pass Criteria**: DU can reach e2term via ric-network

---

## Test Phase 7: Interface Validation

### Test 7.1: F1 Interface (CU <-> DU)
```bash
# Check CU logs for F1 setup
docker logs srs_cu 2>&1 | grep -i "f1" | head -10

# Check DU logs for F1 setup
docker logs srs_du 2>&1 | grep -i "f1" | head -10
```

**Pass Criteria**: F1 setup messages in both CU and DU logs

### Test 7.2: N2/NGAP Interface (CU -> AMF)
```bash
# Check CU logs for NGAP/N2 connection
docker logs srs_cu 2>&1 | grep -i "ngap\|n2\|amf" | head -10

# Check AMF logs for incoming connection
docker logs 5g-core-amf 2>&1 | grep -i "ngap\|gnb\|ran" | head -10
```

**Pass Criteria**: NGAP association messages visible

### Test 7.3: E2 Interface (DU -> RIC)
```bash
# Check DU logs for E2 connection
docker logs srs_du 2>&1 | grep -i "e2\|ric\|sctp" | head -10

# Check e2term logs for incoming E2 connection
docker logs ric-e2term 2>&1 | grep -i "e2\|sctp\|connect\|association" | head -10

# Check e2mgr for registered nodeB
docker exec ric-e2mgr curl -s http://localhost:3800/v1/nodeb/states | python3 -m json.tool
```

**Pass Criteria**: E2 association established between DU and e2term

### Test 7.4: ZMQ Virtual Radio (DU <-> UE)
```bash
# Check DU logs for ZMQ
docker logs srs_du 2>&1 | grep -i "zmq\|radio" | head -5

# Check UE logs for ZMQ connection and cell search
docker logs srsue_5g_zmq 2>&1 | grep -i "zmq\|cell\|found\|sync" | head -10
```

**Pass Criteria**: ZMQ radio link established between DU and UE

---

## Test Phase 8: End-to-End Validation

### Test 8.1: Comprehensive Health Check
```bash
./scripts/check-nf-health.sh
# Expected: All containers healthy across 3 stacks
```

**Pass Criteria**: Health script reports all services running

### Test 8.2: UE Registration
```bash
# Check UE logs for registration
docker logs srsue_5g_zmq 2>&1 | grep -i "register\|attach\|connected\|rrc" | head -10

# Check AMF for accepted registration
docker logs 5g-core-amf 2>&1 | grep -i "registration.*accept\|initial.*registration" | tail -5
```

**Pass Criteria**: UE registration accepted by core network

### Test 8.3: PDU Session Establishment
```bash
# Check SMF for PDU session
docker logs 5g-core-smf 2>&1 | grep -i "pdu.*session\|session.*created" | head -5

# Check UPF for GTP tunnel
docker logs 5g-core-upf 2>&1 | grep -i "gtp.*session\|pfcp.*session" | head -5
```

**Pass Criteria**: PDU session established through SMF/UPF

### Test 8.4: Restart Resilience
```bash
# Restart all stacks
./scripts/launch-all.sh --down
sleep 10
./scripts/launch-all.sh

# Wait for full startup
sleep 60

# Verify all healthy
./scripts/launch-all.sh --status
./scripts/check-nf-health.sh
```

**Pass Criteria**: All containers restart cleanly

### Test 8.5: Resource Baseline
```bash
# Record resource usage
docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}" | head -30
```

**Pass Criteria**: Baseline metrics recorded, no excessive usage

---

## Troubleshooting Test Failures

### Core containers won't start
```bash
docker-compose down -v    # WARNING: Deletes MongoDB data
docker build --no-cache -f dockerfiles/Dockerfile.5gscore -t teste-core:latest .
docker-compose up -d
```

### RIC containers crash
```bash
# Redis must start first
docker logs ric-dbaas
# Check e2term needs Redis available
docker-compose -f docker-compose.ric.yml restart
```

### CU/DU images not found
```bash
docker build -f dockerfiles/Dockerfile.srsran -t srsran-split:latest .
docker build -f dockerfiles/Dockerfile.srsue -t srsue:latest .
```

### Multi-homing not working
```bash
# Verify network exists and is external
docker network ls | grep -E "5g-core-network|ran-network|ric-network"

# CU needs both ran-network and 5g-core-network to exist before starting
# Start core first, then CU/DU
```

### E2 SCTP connection refused
```bash
# Verify e2term is listening
docker exec ric-e2term netstat -tlnp | grep 36421

# Verify DU can reach e2term
docker exec srs_du ping -c 1 172.22.0.210

# Check e2term config
docker exec ric-e2term cat /opt/e2/config/config.conf
```

### Data plane not working
```bash
# Verify host TUN interfaces
ip link show | grep ogstun

# Verify IP forwarding
sysctl net.ipv4.ip_forward

# Verify NAT rules
sudo iptables -t nat -L -n | grep MASQUERADE
```

---

## Test Report Template

```markdown
# O-RAN Stack Deployment Test Report

**Date**: _______________
**Tester**: _______________
**Environment**: Linux ________, Docker ________, Compose ________

## Pre-Deployment
- [ ] CPU cores >= 4: ________
- [ ] RAM >= 8GB: ________
- [ ] Disk >= 50GB: ________
- [ ] All Docker images built

## Phase 1: Infrastructure
- [ ] TUN interfaces created (ogstun, ogstun2, ogstun3)
- [ ] TUN IPs correct

## Phase 2: 5G Core
- [ ] All 18+ core containers running
- [ ] Core network: 172.20.0.0/24
- [ ] MongoDB healthy

## Phase 3: Core NF Health
- [ ] No critical errors in NF logs
- [ ] NRF has registered NFs
- [ ] Inter-NF connectivity OK
- [ ] UPF data plane ready

## Phase 4: WebUI & Subscribers
- [ ] WebUI HTTP 200 on localhost:9999
- [ ] 2 subscribers present (IMSI 00101...)
- [ ] Security keys match ue.conf

## Phase 5: Near-RT RIC
- [ ] All 6 RIC containers running
- [ ] RIC network: 172.22.0.0/24
- [ ] Redis (DBAAS) healthy
- [ ] e2term listening on 36421
- [ ] e2mgr API responding
- [ ] A1 mediator healthy

## Phase 6: CU/DU + UE
- [ ] All 3 RAN containers running
- [ ] RAN network: 172.21.0.0/24
- [ ] CU multi-homed (ran + core)
- [ ] DU multi-homed (ran + ric)
- [ ] CU -> AMF connectivity
- [ ] DU -> CU connectivity
- [ ] DU -> e2term connectivity

## Phase 7: Interface Validation
- [ ] F1 interface (CU <-> DU)
- [ ] N2/NGAP interface (CU -> AMF)
- [ ] E2 interface (DU -> RIC)
- [ ] ZMQ radio (DU <-> UE)

## Phase 8: End-to-End
- [ ] Health check passes (all stacks)
- [ ] UE registration accepted
- [ ] PDU session established
- [ ] Restart resilience OK
- [ ] Resource baseline recorded

## Issues Encountered
[List any issues, workarounds, resolutions]

## Summary
**Overall Status**: [ ] PASS [ ] PASS WITH ISSUES [ ] FAIL
**Approved for Production**: [ ] YES [ ] NO [ ] PENDING
```

---

## Next Steps After Testing

### If All Tests Pass
1. Document results in test report
2. Back up logs: `./scripts/export-logs.sh`
3. Proceed to xApp development against the RIC
4. Consider hardware radio (USRP) testing

### If Tests Fail
1. Check Troubleshooting section above
2. Collect logs: `docker logs <container-name>`
3. Verify image builds completed successfully
4. Ensure startup ordering (core -> RIC -> CU/DU)
5. Re-run only the failing test phase
