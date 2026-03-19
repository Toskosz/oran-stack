# Production Deployment Guide - Open5GS 5G Core Network

**Last Updated**: March 2026  
**Version**: 1.0 - Production Ready

## Table of Contents

1. [Overview](#overview)
2. [System Requirements](#system-requirements)
3. [Quick Start](#quick-start)
4. [Detailed Setup](#detailed-setup)
5. [WebUI Access & Subscriber Management](#webui-access--subscriber-management)
6. [Data Plane Validation](#data-plane-validation)
7. [Troubleshooting](#troubleshooting)
8. [Production Considerations](#production-considerations)
9. [Monitoring and Logging](#monitoring-and-logging)
10. [Configuration Reference](#configuration-reference)

---

## Overview

This deployment provides a **production-ready 5G Core Network** based on Open5GS, with all 17 network functions (12 5G + 5 4G/EPC) containerized and orchestrated via Docker Compose.

### Key Features

✅ **Complete 5G & 4G Architecture**
- All NFs: NRF, SCP, SEPP, AMF, SMF, UPF, AUSF, UDM, PCF, NSSF, BSF, UDR (5G)
- Legacy: MME, SGW-C, SGW-U, HSS, PCRF (4G/EPC)

✅ **Full Data Plane Support**
- UE attachment and PDU session establishment
- Data forwarding through UPF
- Internet connectivity for UEs via NAT

✅ **Environment-Based Configuration**
- Customizable PLMN ID, TAC, NSSAI via `.env`
- No Docker rebuild required for config changes
- Per-NF YAML configuration files

✅ **Web-Based Management**
- Open5GS WebUI for subscriber management
- Add/edit subscribers without CLI
- Security key configuration

✅ **Comprehensive Monitoring**
- Health checks for all services
- Prometheus metrics endpoints
- Structured logging

---

## System Requirements

### Hardware
- **CPU**: 4+ cores (8+ recommended)
- **RAM**: Minimum 8GB (16GB recommended)
- **Disk**: 50GB+ (SSD recommended)
- **Network**: Host with internet access for data plane connectivity

### Software
- **Linux**: Ubuntu 22.04 LTS (other distributions supported with adjustments)
- **Linux Kernel**: 5.0+ with TUN/TAP support
- **Docker**: 20.10+ 
- **Docker Compose**: 1.29+
- **Root Access**: Required for TUN setup and network configuration

### Network Prerequisites
- TUN/TAP kernel module enabled (check: `cat /proc/net/dev | grep -q tun && echo OK`)
- No conflicting Docker networks (default subnet: 172.20.0.0/16)
- No existing iptables rules blocking Docker traffic

---

## Quick Start

### 1. Clone Repository
```bash
git clone https://github.com/Toskosz/oran-stack.git
cd oran-stack
```

### 2. Setup Host Network (One-time, requires sudo)
```bash
# Create TUN interfaces
sudo ./setup-host-tun.sh

# Configure IP forwarding and NAT
sudo ./setup-host-network.sh
```

### 3. Build Docker Images
```bash
# Build core 5G network functions
docker-compose build 5g-core-nrf

# Build WebUI (takes ~5-10 minutes)
docker-compose build 5g-core-webui
```

### 4. Start the Deployment
```bash
# Start all services
./launch-5g-core.sh logs

# Wait 30-60 seconds for all services to start
# Check logs in ./logs/ directory
```

### 5. Access WebUI
```
URL: http://localhost:9999
Username: admin
Password: 1423
```

---

## Detailed Setup

### Step 1: Verify Prerequisites

```bash
# Check Docker is installed and running
docker --version
docker-compose --version
docker ps  # Should show "Cannot connect to Docker daemon" if not running, fix with: sudo systemctl start docker

# Verify TUN/TAP support
cat /proc/net/dev | grep -q tun && echo "TUN support OK" || echo "ERROR: No TUN support"

# Check for root access
sudo whoami  # Should output: root
```

### Step 2: Clone and Navigate

```bash
git clone https://github.com/Toskosz/oran-stack.git
cd oran-stack
ls -la
# You should see:
# - configs/                (NF configuration templates)
# - docker-compose.yml      (Service orchestration)
# - Dockerfile.5gscore      (5G core container definition)
# - Dockerfile.webui        (WebUI container definition)
# - setup-host-tun.sh       (TUN interface setup)
# - setup-host-network.sh   (Network forwarding setup)
# - launch-5g-core.sh       (Deployment launcher)
```

### Step 3: Configure TUN Interfaces

```bash
# Create TUN interfaces on the host
sudo ./setup-host-tun.sh

# Expected output:
# [OK] Host TUN setup complete!
# 
# Verify:
ip tuntap list
# Should show: ogstun, ogstun2, ogstun3 as 'tun' type

ip addr show dev ogstun
# Should show: 10.45.0.1/16 and 2001:db8:cafe::1/48
```

### Step 4: Configure Data Plane Networking

```bash
# Enable IP forwarding and NAT
sudo ./setup-host-network.sh

# Expected output:
# [OK] Data plane network setup complete!
#
# Verify:
sysctl net.ipv4.ip_forward              # Should output: 1
iptables -t nat -L -n | grep MASQUERADE  # Should show rules for 10.45.0.0/16, etc.
```

### Step 5: Customize Configuration (Optional)

Edit `.env` to customize:

```bash
# PLMN configuration (default: 001/01 for testing)
MCC=001          # Change to your country code
MNC=01           # Change to your operator code
TAC=1            # Tracking Area Code

# Logging
LOG_LEVEL=info   # Can be: debug, info, warning, error
```

### Step 6: Build Docker Images

```bash
# Build the 5G core container (first time: ~10-15 minutes)
docker-compose build 5g-core-nrf
# All NF containers will use the same image: teste-core:latest

# Build the WebUI container (first time: ~5-10 minutes)
docker-compose build 5g-core-webui
# WebUI image: open5gs-webui:latest

# Subsequent builds are faster (only if you make changes)
```

### Step 7: Start the Deployment

```bash
# Start all services (MongoDB, NFs, WebUI)
./launch-5g-core.sh logs

# Expected output:
# ✓ MongoDB healthy
# ✓ All 18 services started
# ✓ Logs exported to ./logs/

# Wait 30-60 seconds for NFs to register with NRF
```

### Step 8: Verify Deployment

```bash
# Check running containers
docker-compose ps

# Expected:
# NAME              STATUS              PORTS
# 5g-mongodb        Up (healthy)        27017
# 5g-core-nrf       Up                  7777
# 5g-core-scp       Up                  7777
# ... (all 17 NF containers)
# 5g-core-webui     Up                  9999/tcp

# View logs
tail -f logs/*.log

# Check MongoDB replica set
docker exec 5g-core-mongodb mongosh --eval "rs.status()"
# Should show: members.state = 1 (PRIMARY)

# Check NRF registration
docker exec 5g-core-amf curl -s http://172.20.0.10:7777/nrf/v1/nf-instances
# Should return JSON list of registered NFs
```

---

## WebUI Access & Subscriber Management

### Access WebUI

```
URL: http://localhost:9999
Browser: Chrome, Firefox, Safari (any modern browser)
```

### First Login

```
Username: admin
Password: 1423
```

⚠️ **IMPORTANT**: Change the default password immediately!

### Add a New Subscriber

1. **Navigate to Subscriber Menu**
   - Click "Subscriber" in left sidebar
   - Click "+" button to add new subscriber

2. **Fill in Subscriber Information**
   - IMSI: 999700000000001 (format: MCC+MNC+11 digits)
     - MCC: 999, MNC: 70, Subscriber ID: 00000000001
   - MSISDN: +82100000001 (phone number, optional)
   - Subscriber Status: Granted
   - Access Restriction Data: 32
   - Subscribed RAU/TAU Timer: 12

3. **Configure Subscriber Security**
   - Click "Authentication" tab
   - K (Subscriber Key): 8baf473f2f8fd09487cccbd7097c6862
   - OPc (Operator Code): 8e27b6af0e692e750f32667a3b14605d
   - AMF: 32770
   - These are test values. **Never use in production!**

4. **Configure APN (Access Point Name)**
   - Click "Access Point Names" tab
   - Add APN: "internet"
   - Type: IPv4
   - QoS Class Identifier: 9 (Best Effort)
   - MBR Downlink: 1024 Mbps
   - MBR Uplink: 1024 Mbps

5. **Configure Network Slices**
   - Click "Network Slices" tab
   - Add: SST=1 (eMBB slice)
   - SD: 0 (optional)

6. **Save**
   - Click "SAVE" button
   - Subscriber should be immediately available (no restart needed)

### Pre-loaded Sample Subscribers

Two sample subscribers are automatically initialized:

**5G Subscriber**:
- IMSI: 999700000000001
- K: 8baf473f2f8fd09487cccbd7097c6862
- OPc: 8e27b6af0e692e750f32667a3b14605d

**4G Subscriber**:
- IMSI: 999700000000002
- K: 8baf473f2f8fd09487cccbd7097c6862
- OPc: 8e27b6af0e692e750f32667a3b14605d

---

## Data Plane Validation

### Verify UE Connectivity

To test full data plane functionality, use a 5G/4G UE simulator (e.g., srsRAN):

```bash
# 1. Start UE simulator (example with srsRAN)
# Configure gNB/eNB to connect to:
#   AMF IP: 172.20.0.5 (for 5G)
#   MME IP: 172.20.0.2 (for 4G)
#   NGAP Port: 38412 (5G)
#   S1AP Port: 36412 (4G)

# 2. Verify UE attachment (from host)
docker exec 5g-core-amf tail -20 /var/log/open5gs/amf.log | grep "Registration is accepted"

# 3. Verify PDU Session (5G)
docker exec 5g-core-smf tail -20 /var/log/open5gs/smf.log | grep "PDU Session"

# 4. Test data connectivity from UE
ping -I <UE_IP> 8.8.8.8
# Should receive ICMP replies through the core network
```

### Network Configuration Verification

```bash
# Check TUN interface status
ip addr show dev ogstun
# Should show: 10.45.0.1/16 and 2001:db8:cafe::1/48

# Check IP forwarding
sysctl net.ipv4.ip_forward
# Should output: net.ipv4.ip_forward = 1

# Check NAT rules
iptables -t nat -L -n | grep -A5 "POSTROUTING"
# Should show MASQUERADE rules for 10.45.0.0/16, etc.

# Check firewall status
ufw status
# Should output: Status: inactive

# Monitor UE traffic
tcpdump -i ogstun -nn icmp
# Capture ICMP packets from UE pings
```

---

## Troubleshooting

### Issue: Docker Build Fails

**Symptom**: `docker-compose build` fails with network errors

**Solution**:
```bash
# 1. Check Docker can access network
docker run --rm curlimages/curl curl -I https://github.com

# 2. Check DNS resolution
docker run --rm alpine nslookup github.com

# 3. Try building with --no-cache
docker-compose build --no-cache 5g-core-nrf

# 4. If still failing, check proxy settings
# Edit Dockerfile or ~/.docker/config.json
```

### Issue: NFs Not Starting

**Symptom**: `docker-compose ps` shows containers "Exiting" or "Restarting"

**Solution**:
```bash
# Check container logs
docker logs 5g-core-nrf -f

# Common issues:
# 1. TUN interfaces not created
docker exec 5g-core-nrf ip tuntap list
#    If empty, TUN was not created. Run: sudo ./setup-host-tun.sh

# 2. MongoDB connection error
docker logs 5g-core-mongodb
#    If MongoDB fails, check disk space: df -h

# 3. Config file template substitution failed
docker exec 5g-core-nrf ls -la /open5gs/install/etc/open5gs/
#    Should show nrf.yaml, scp.yaml, etc.

# 4. Port conflicts
sudo netstat -tlnp | grep 172.20
#    Check if NF ports are in use on host
```

### Issue: WebUI Not Accessible

**Symptom**: `curl http://localhost:9999` times out or refuses connection

**Solution**:
```bash
# Check if WebUI container is running
docker ps | grep webui

# If not running, check logs
docker logs 5g-core-webui

# Verify port mapping
docker port 5g-core-webui
# Should show: 9999/tcp -> 0.0.0.0:9999

# If port is occupied by another service
sudo lsof -i :9999
# Kill the process or change WebUI port in docker-compose.yml
```

### Issue: MongoDB Won't Start

**Symptom**: MongoDB container exits with error

**Solution**:
```bash
# Check volume permissions
ls -la mongodb_data/
# Owner should be readable by docker process

# Fix permissions
sudo chown -R 999:999 ./mongodb_data/
sudo chmod 755 ./mongodb_data/

# Check available disk space
df -h /home
# Ensure at least 10GB free

# Try rebuilding
docker-compose down -v  # WARNING: Deletes database!
docker-compose up mongodb
```

### Issue: Data Plane Not Working

**Symptom**: UE can attach but cannot send/receive data

**Solution**:
```bash
# 1. Verify setup-host-network.sh was run
sysctl net.ipv4.ip_forward
# Must be: 1

# 2. Check NAT rules exist
iptables -t nat -L -n | grep MASQUERADE
# Must show rules for 10.45.0.0/16

# 3. Verify TUN interfaces are up
ip link show | grep ogstun
# Should show: <UP,RUNNING,NOARP>

# 4. Check firewall isn't blocking
ufw status
# Should show: inactive

# 5. Monitor UPF processing
docker logs 5g-core-upf -f | grep -i gtp
# Should show GTP-U session processing
```

---

## Production Considerations

### Security

⚠️ **CRITICAL CHANGES FOR PRODUCTION**:

1. **Change Default Credentials**
   ```bash
   # WebUI password
   # Login to WebUI, go to Account menu, change password
   
   # MongoDB credentials (if exposed to network)
   # Update MONGODB_URI with username:password
   ```

2. **Use Real Security Keys**
   ```bash
   # Replace test keys with real 3GPP-compliant keys
   # K, OPc, AMF must be generated by your network operator
   # Never share or expose these keys!
   ```

3. **Enable TLS/HTTPS**
   ```bash
   # Update SEPP config for secure inter-PLMN communication
   # Generate certificates for NF mutual authentication
   # Enable TLS on SBI interfaces
   ```

4. **Network Isolation**
   ```bash
   # Use firewall rules to restrict access
   # Allow only authorized gNBs/eNBs to connect to AMF
   # Restrict WebUI access to management network only
   ```

5. **Backup Strategy**
   ```bash
   # Backup MongoDB data regularly
   docker exec 5g-core-mongodb mongodump --out /backup/
   
   # Backup configuration files
   cp -r configs/ ./backup/configs_$(date +%Y%m%d)/
   
   # Test recovery procedures
   ```

### Monitoring

**Enable Prometheus Metrics**:
```bash
# All NFs expose metrics on port 9090
# Example: http://172.20.0.5:9090/metrics (AMF metrics)

# Integrate with Prometheus for monitoring:
# Add scrape config:
# - job_name: 'open5gs'
#   static_configs:
#   - targets: ['172.20.0.5:9090', '172.20.0.4:9090', '172.20.0.7:9090']
```

**Log Aggregation**:
```bash
# All logs are in ./logs directory
# Send to centralized logging (e.g., ELK stack):
# - Filebeat monitors ./logs/
# - Sends to Elasticsearch
# - Visualize in Kibana
```

### High Availability

For production HA deployment:

1. **Database Replication**
   ```bash
   # Extend MongoDB replica set to 3 nodes
   # Update docker-compose.yml to add mongodb-1, mongodb-2
   # Each in different availability zone
   ```

2. **NF Redundancy**
   ```bash
   # Deploy multiple instances of critical NFs (AMF, SMF, UPF)
   # Use load balancer for traffic distribution
   # Configure NRF-based discovery
   ```

3. **Failover Handling**
   ```bash
   # Configure health checks for all services
   # Use external orchestrator (Kubernetes recommended)
   # Implement graceful shutdown procedures
   ```

### Performance Tuning

```bash
# Increase system limits
ulimit -n 65536  # File descriptors

# Optimize kernel parameters
sudo sysctl -w net.core.rmem_max=134217728
sudo sysctl -w net.core.wmem_max=134217728
sudo sysctl -w net.ipv4.tcp_rmem="4096 87380 67108864"

# Monitor resource usage
docker stats

# Profile NF performance
docker exec 5g-core-nrf ps aux | grep open5gs-nrfd
```

---

## Monitoring and Logging

### View Logs

```bash
# All container logs
docker-compose logs -f

# Specific NF logs
docker logs 5g-core-amf -f
docker logs 5g-core-upf -f

# Historical logs in files
tail -100 /var/log/open5gs/amf.log
tail -100 /var/log/open5gs/upf.log

# Search logs for errors
docker logs 5g-core-nrf 2>&1 | grep -i error
```

### Check Service Health

```bash
# Docker Compose health status
docker-compose ps

# Detailed service info
docker-compose logs | tail -50

# NF registration check
docker exec 5g-core-amf curl -s http://172.20.0.10:7777/nrf/v1/nf-instances | jq .

# MongoDB health
docker exec 5g-core-mongodb mongosh --eval "db.adminCommand('ping')"
```

### Common Log Patterns

**Successful Startup**:
```
[app] INFO: NRF initialize...done
[sbi] INFO: nghttp2_server() [http://172.20.0.10]:7777
[app] INFO: NRF starts successfully
```

**UE Attachment**:
```
[gmm] INFO: UE[AMF:SN] Registration is accepted
[gmm] INFO: Initial Registration
[5gc] INFO: UE[AMF:SN] Start 5G Connection Management / Non-Access Stratum
```

**PDU Session Establishment**:
```
[smf] INFO: Session created
[upf] INFO: GTP-U Session created
[pfcp] INFO: PFCP Session created
```

---

## Configuration Reference

### Environment Variables

All variables in `.env` are injected into NF configuration YAML files:

```yaml
# In configs/nrf.yaml
nrf:
  serving:
    - plmn_id:
        mcc: ${MCC}        # From .env: MCC=001
        mnc: ${MNC}        # From .env: MNC=01
```

### YAML Configuration Files

Each NF has a corresponding YAML file in `configs/`:

- **5G NFs**: nrf.yaml, scp.yaml, sepp1.yaml, amf.yaml, smf.yaml, upf.yaml, ausf.yaml, udm.yaml, pcf.yaml, nssf.yaml, bsf.yaml, udr.yaml
- **4G NFs**: mme.yaml, sgwc.yaml, sgwu.yaml, hss.yaml, pcrf.yaml

To customize:
1. Edit `configs/<nf>.yaml`
2. Add new `${VARIABLE}` placeholders
3. Add variable to `.env`
4. Restart container: `docker-compose restart <service>`

### Docker Compose Services

All services in docker-compose.yml:

- **mongodb**: MongoDB database (port 27017)
- **5g-core-webui**: WebUI management interface (port 9999)
- **5g-core-nrf**: Network Repository Function
- **5g-core-scp**: Service Communication Proxy
- **5g-core-sepp**: Security Edge Protection Proxy
- **5g-core-amf**: Access & Mobility Management
- **5g-core-smf**: Session Management
- **5g-core-upf**: User Plane Function
- **5g-core-ausf**: Authentication Server
- **5g-core-udm**: Unified Data Management
- **5g-core-pcf**: Policy Control
- **5g-core-nssf**: Network Slice Selection
- **5g-core-bsf**: Binding Support
- **5g-core-udr**: Unified Data Repository
- **5g-core-mme**: Mobility Management (4G)
- **5g-core-sgwc**: Serving Gateway Control
- **5g-core-sgwu**: Serving Gateway User
- **5g-core-hss**: Home Subscriber Server
- **5g-core-pcrf**: Policy & Charging Rules

---

## Support and Troubleshooting

For additional help:

1. **Check Logs**: `docker-compose logs -f`
2. **Review Configuration**: `cat configs/nrf.yaml` (example)
3. **Inspect Containers**: `docker inspect 5g-core-nrf`
4. **Test Connectivity**: `docker exec 5g-core-amf curl -v http://172.20.0.10:7777/nrf/v1/nf-instances`

---

**Remember**: This is a lab/testing deployment. For production use, conduct proper security audits, load testing, and disaster recovery planning.
