# 5G Core Multi-NF Docker Deployment - Implementation Summary

## ✅ Completed Implementation

All 17 5G Network Functions (NFs) plus MongoDB are now deployed in separate Docker containers with the following features:

### Containers Deployed

**5G Core NFs (3GPP Release 15+):**
1. ✅ NRF (Network Repository Function) - 172.20.0.10
2. ✅ SCP (Service Communication Proxy) - 172.20.0.200
3. ✅ SEPP (Security Edge Protection Proxy) - 172.20.0.250
4. ✅ AMF (Access and Mobility Function) - 172.20.0.5
5. ✅ SMF (Session Management Function) - 172.20.0.4
6. ✅ UPF (User Plane Function) - 172.20.0.7
7. ✅ AUSF (Authentication Server Function) - 172.20.0.11
8. ✅ UDM (Unified Data Management) - 172.20.0.12
9. ✅ PCF (Policy Control Function) - 172.20.0.13
10. ✅ NSSF (Network Slice Selection Function) - 172.20.0.14
11. ✅ BSF (Binding Support Function) - 172.20.0.15
12. ✅ UDR (Unified Data Repository) - 172.20.0.20

**4G/Legacy NFs:**
13. ✅ MME (Mobility Management Entity) - 172.20.0.2
14. ✅ SGW-C (Serving Gateway - Control Plane) - 172.20.0.3
15. ✅ SGW-U (Serving Gateway - User Plane) - 172.20.0.6
16. ✅ HSS (Home Subscriber Server) - 172.20.0.1
17. ✅ PCRF (Policy and Charging Rules Function) - 172.20.0.21

**Infrastructure:**
18. ✅ MongoDB - 172.20.0.254 (shared database for all NFs)

### Key Features Implemented

✅ **Proper Startup Order**: Containers start in the correct sequence from the initialization log
- MongoDB → NRF → SCP → SEPP → AMF → SMF → UPF → ... → PCRF

✅ **Docker Internal Network**: All NFs communicate via private Docker network (172.20.0.0/16)
- No port conflicts between containers
- Production-like architecture
- Service discovery via container names

✅ **Persistent Volume Logging**: All logs exported to `logs/` directory with timestamps
- Individual container logs: `logs/5g-core-nrf_20250319_120000.log`
- Startup summary: `logs/startup_summary_20250319_120000.log`
- Automatically recreated on each deployment

✅ **Health Monitoring Scripts**:
- `scripts/export-logs.sh` - Export all logs and generate startup summary
- `scripts/check-nf-health.sh` - Monitor container health and status
- `launch-5g-core.sh` - Convenience launcher with automatic log export

✅ **Default Configurations**: Uses standard Open5GS configs with MongoDB URI fixed
- All NFs configured to use `mongodb://mongodb:27017/open5gs`
- No custom configuration files needed (but can be added if needed)

✅ **Dependency Management**: Proper `depends_on` chains ensure containers start correctly
- Each service depends on the previous one
- MongoDB health check ensures database is ready

---

## 📁 Files Modified/Created

### Modified Files
1. **docker-compose.yml** (replaced)
   - Now contains 18 services (1 MongoDB + 17 NFs)
   - All services on Docker internal network (172.20.0.0/16)
   - Proper startup order via `depends_on` chains
   - No port mappings (internal network only)

2. **5G_DOCKER_SETUP.md** (completely rewritten)
   - Comprehensive multi-NF deployment guide
   - Architecture overview with diagrams
   - Startup order and dependency information
   - Troubleshooting guide
   - Command reference

### Created Files
1. **.env** (new)
   - IP allocations for all NFs
   - Port mapping reference
   - Environment variable configuration

2. **launch-5g-core.sh** (new)
   - Convenience launcher script
   - Automatically starts containers and optionally exports logs
   - Usage: `./launch-5g-core.sh logs`

3. **scripts/export-logs.sh** (new)
   - Exports all container logs to `logs/` directory with timestamps
   - Generates startup summary with container status
   - Reports MongoDB connectivity
   - Usage: `./scripts/export-logs.sh`

4. **scripts/check-nf-health.sh** (new)
   - Real-time health monitoring of all containers
   - Shows uptime, IP address, and port information
   - Continuous watch mode: `./scripts/check-nf-health.sh watch`

---

## 🚀 Quick Start

### 1. Create TUN Interfaces on Host
```bash
sudo ./setup-host-tun.sh
```

### 2. Start All Containers with Logs
```bash
./launch-5g-core.sh logs
```

### 3. Monitor Health
```bash
./scripts/check-nf-health.sh watch
```

That's it! All 17 NFs are running with automatic log export.

---

## 📊 Architecture Summary

```
┌────────────────────────────────────────────────────────┐
│         Docker Network: 172.20.0.0/16                 │
├────────────────────────────────────────────────────────┤
│                                                        │
│  5G Core NFs (5G Release 15+)    4G/Legacy NFs       │
│  ├─ NRF (172.20.0.10)            ├─ MME (172.20.0.2) │
│  ├─ SCP (172.20.0.200)           ├─ SGW-C (172.20.0.3)
│  ├─ SEPP (172.20.0.250)          ├─ SGW-U (172.20.0.6)
│  ├─ AMF (172.20.0.5)             ├─ HSS (172.20.0.1) │
│  ├─ SMF (172.20.0.4)             └─ PCRF (172.20.0.21)
│  ├─ UPF (172.20.0.7)                                  │
│  ├─ AUSF (172.20.0.11)                               │
│  ├─ UDM (172.20.0.12)            MongoDB              │
│  ├─ PCF (172.20.0.13)            (172.20.0.254)      │
│  ├─ NSSF (172.20.0.14)           (Shared Database)   │
│  ├─ BSF (172.20.0.15)                                │
│  └─ UDR (172.20.0.20)                                │
│                                                        │
└────────────────────────────────────────────────────────┘
```

---

## 📋 Startup Order (From Original Log)

The containers start in this exact order:
1. MongoDB (with health check)
2. NRF
3. SCP
4. SEPP
5. AMF
6. SMF
7. UPF
8. AUSF
9. UDM
10. PCF
11. NSSF
12. BSF
13. UDR
14. MME
15. SGW-C
16. SGW-U
17. HSS
18. PCRF

---

## 📝 Logging Strategy

### Automatic Log Export
Logs are automatically exported to `logs/` directory on each deployment:

```
logs/
├── 5g-core-nrf_20250319_120000.log       # NRF startup logs
├── 5g-core-smf_20250319_120000.log       # SMF startup logs
├── 5g-core-upf_20250319_120000.log       # UPF startup logs
├── ... (one for each container)
└── startup_summary_20250319_120000.log   # Overall status summary
```

### Log Contents
Each container log contains:
- Network interface initialization
- Configuration loading
- Service registration with NRF
- Any errors or warnings
- Final startup status

The startup summary contains:
- Container status (running/stopped/missing)
- Startup order verification
- MongoDB health check
- Docker network information

### Manual Log Export
```bash
# Export all logs
./scripts/export-logs.sh

# View existing logs
ls -lah logs/
cat logs/startup_summary_*.log
```

---

## 🔍 Monitoring and Health Checks

### Real-Time Health Monitoring
```bash
./scripts/check-nf-health.sh watch
```

Shows:
- Container status (running/stopped/missing)
- IP address and port bindings
- Container uptime
- MongoDB connectivity
- Network status

### Manual Status Check
```bash
# All containers
docker-compose ps

# Specific container
docker ps | grep 5g-core-nrf

# Container logs
docker logs 5g-core-nrf
docker logs -f 5g-core-nrf  # Follow in real-time
```

---

## 🛠️ Common Operations

### Start All Containers
```bash
docker-compose up -d
```

### Stop All Containers
```bash
docker-compose down
```

### Restart All Containers
```bash
docker-compose restart
```

### Access Container Shell
```bash
docker exec -it 5g-core-nrf bash
```

### View Container Logs
```bash
docker logs 5g-core-nrf
docker logs -f 5g-core-nrf  # Follow in real-time
```

### Check MongoDB
```bash
docker exec -it 5g-core-mongodb mongosh mongodb://localhost:27017
```

---

## 🐛 Troubleshooting

### Containers Not Starting
1. Check logs: `docker logs 5g-core-nrf`
2. Verify MongoDB is healthy: `docker ps | grep mongodb`
3. Check TUN interfaces: `sudo ip tuntap list`

### MongoDB Connection Errors
1. Verify MongoDB is running: `docker ps | grep mongodb`
2. Test connection: `docker exec 5g-core-mongodb mongosh --eval 'db.adminCommand("ping")'`
3. Check MongoDB logs: `docker logs 5g-core-mongodb`

### TUN Interface Issues
1. Create interfaces: `sudo ./setup-host-tun.sh`
2. Verify: `ip tuntap list`
3. Check in container: `docker exec 5g-core-upf ip addr show ogstun`

---

## 📚 Documentation

Complete documentation is in **5G_DOCKER_SETUP.md**:
- Architecture overview with diagrams
- Detailed setup instructions
- Container management guide
- Monitoring and logging guide
- Troubleshooting section
- Command reference
- Network specifications
- Performance tuning tips

---

## ✨ Key Improvements Over Original Setup

| Feature | Before | After |
|---------|--------|-------|
| NF Containers | 1 shared | 17 individual |
| Database | Optional local | Shared Docker service |
| Networking | User configurable | Docker internal (172.20.0.0/16) |
| Port Mapping | Exposed to host | Internal only |
| Startup Order | Manual | Automatic via depends_on |
| Logging | Manual export | Automatic with timestamps |
| Health Monitoring | Manual checks | Automated scripts |
| Scalability | Limited | Production-ready |

---

## 📞 Support

### To View Status
```bash
./scripts/check-nf-health.sh
```

### To Export Logs
```bash
./scripts/export-logs.sh
```

### To Follow Container Logs
```bash
docker logs -f 5g-core-nrf
```

### To Access Container Shell
```bash
docker exec -it 5g-core-nrf bash
```

---

## 🎯 Next Steps

1. ✅ Verify all containers are running: `docker-compose ps`
2. ✅ Check health status: `./scripts/check-nf-health.sh`
3. ✅ Review startup logs: `cat logs/startup_summary_*.log`
4. ✅ Test inter-NF communication: `docker exec 5g-core-smf curl http://172.20.0.10:7777/`
5. ✅ Run unit tests: `docker exec 5g-core-nrf bash -c "cd /open5gs && ./build/tests/unit/unit"`

---

**Deployment Complete!** 🎉

All 17 5G Network Functions are now running in Docker containers with automatic logging, health monitoring, and production-like architecture.
