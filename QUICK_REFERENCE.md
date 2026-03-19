# 5G Core Multi-NF Docker - Quick Reference

## 🚀 Start Fresh Deployment

```bash
# 1. Create TUN interfaces on host (one-time)
sudo ./setup-host-tun.sh

# 2. Start all 17 NFs with automatic logging
./launch-5g-core.sh logs

# 3. Monitor health (in another terminal)
./scripts/check-nf-health.sh watch
```

---

## 📋 Check Status

```bash
# Quick status
docker-compose ps

# Detailed health report
./scripts/check-nf-health.sh

# Continuous monitoring
./scripts/check-nf-health.sh watch
```

---

## 📝 View Logs

```bash
# All containers at once
docker-compose logs

# Follow specific container
docker logs -f 5g-core-nrf

# Export all logs
./scripts/export-logs.sh

# View exported logs
ls -lah logs/
cat logs/startup_summary_*.log
```

---

## 🛑 Stop Everything

```bash
docker-compose down
```

---

## 🔄 Restart

```bash
docker-compose restart
```

---

## 🐚 Access Container

```bash
# Open bash in NRF
docker exec -it 5g-core-nrf bash

# Run command
docker exec 5g-core-nrf ps aux
```

---

## 📊 Container List

| # | NF | Container | IP | Port |
|---|-------|-------------|---------|------|
| 1 | NRF | 5g-core-nrf | 172.20.0.10 | 7777 |
| 2 | SCP | 5g-core-scp | 172.20.0.200 | 7777 |
| 3 | SEPP | 5g-core-sepp | 172.20.0.250 | 7777 |
| 4 | AMF | 5g-core-amf | 172.20.0.5 | 7777 |
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
| - | MongoDB | 5g-mongodb | 172.20.0.254 | 27017 |

---

## 🔍 Verify Connectivity

```bash
# Ping between containers
docker exec 5g-core-smf ping 172.20.0.10

# Test specific port
docker exec 5g-core-smf curl http://172.20.0.10:7777/

# Check open ports in container
docker exec 5g-core-smf netstat -tlnp
```

---

## 💾 MongoDB

```bash
# Connect from host
mongosh mongodb://localhost:27017/open5gs

# Connect from container
docker exec -it 5g-core-nrf mongosh mongodb://mongodb:27017/open5gs

# Check replica set status
docker exec 5g-core-mongodb mongosh --eval 'rs.status()'

# Ping MongoDB
docker exec 5g-core-mongodb mongosh --eval 'db.adminCommand("ping")'
```

---

## 🐛 Troubleshooting

### Containers not starting?
```bash
docker logs 5g-core-nrf  # Check specific container
docker-compose logs     # All containers
```

### MongoDB not responding?
```bash
docker ps | grep mongodb          # Check if running
docker logs 5g-core-mongodb       # View logs
docker exec 5g-core-mongodb mongosh --eval 'db.adminCommand("ping")'  # Test
```

### TUN interface issues?
```bash
sudo ip tuntap list              # Check on host
docker exec 5g-core-upf ip addr show ogstun  # Check in container
sudo ./setup-host-tun.sh         # Recreate
```

---

## 📚 Full Documentation

See **5G_DOCKER_SETUP.md** for:
- Complete architecture overview
- Detailed setup instructions
- Advanced configuration
- Performance tuning
- Complete command reference

---

## 📦 File Structure

```
.
├── docker-compose.yml        # All 18 services
├── Dockerfile.5gscore        # NF container image
├── .env                      # Configuration
├── 5G_DOCKER_SETUP.md        # Full documentation
├── DEPLOYMENT_SUMMARY.md     # Implementation details
├── QUICK_REFERENCE.md        # This file
├── launch-5g-core.sh         # Launcher script
├── setup-host-tun.sh         # TUN setup
├── entrypoint.sh             # Container init
├── init-mongodb.js           # MongoDB init
├── scripts/
│   ├── export-logs.sh        # Log export
│   └── check-nf-health.sh    # Health check
└── logs/                     # Auto-generated logs
    ├── 5g-core-*.log
    └── startup_summary_*.log
```

---

## ⚡ One-Liner Commands

```bash
# Start with logging
./launch-5g-core.sh logs

# Stop everything
docker-compose down

# Restart all
docker-compose restart

# Check status
docker-compose ps

# View health
./scripts/check-nf-health.sh watch

# Export logs
./scripts/export-logs.sh

# Ping between NFs
docker exec 5g-core-smf ping 172.20.0.10

# Access NRF shell
docker exec -it 5g-core-nrf bash

# Follow NRF logs
docker logs -f 5g-core-nrf
```

---

## 🆘 Getting Help

1. **Check logs**: `docker logs 5g-core-<nf>`
2. **Run health check**: `./scripts/check-nf-health.sh`
3. **Export logs**: `./scripts/export-logs.sh`
4. **Review documentation**: `5G_DOCKER_SETUP.md`

---

**All 17 5G NFs running in Docker! 🎉**
