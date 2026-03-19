# Deployment Testing Guide - Open5GS 5G Core Network

**Purpose**: Step-by-step instructions to test the production-ready 5G core deployment  
**Target Environment**: Linux (Ubuntu 22.04 LTS recommended)  
**Estimated Duration**: 30-45 minutes for full test suite  
**Difficulty Level**: Intermediate (requires basic Linux and Docker knowledge)

---

## Table of Contents

1. [Pre-Deployment Checklist](#pre-deployment-checklist)
2. [Test Phase 1: Infrastructure Setup](#test-phase-1-infrastructure-setup)
3. [Test Phase 2: Container Deployment](#test-phase-2-container-deployment)
4. [Test Phase 3: NF Health & Connectivity](#test-phase-3-nf-health--connectivity)
5. [Test Phase 4: WebUI Functionality](#test-phase-4-webui-functionality)
6. [Test Phase 5: Data Plane Configuration](#test-phase-5-data-plane-configuration)
7. [Test Phase 6: End-to-End Validation](#test-phase-6-end-to-end-validation)
8. [Troubleshooting Test Failures](#troubleshooting-test-failures)
9. [Test Report Template](#test-report-template)

---

## Pre-Deployment Checklist

Before running any tests, verify your environment meets requirements:

### Hardware Requirements
```bash
# Check CPU cores (need 4+)
nproc
# Expected: 4 or higher

# Check available RAM (need 8GB+)
free -h | grep Mem
# Expected: ~8G or higher in "available" column

# Check disk space (need 50GB+)
df -h /
# Expected: 50G or more available
```

### Software Requirements
```bash
# Verify Docker is installed (20.10+)
docker --version
# Expected output: Docker version 20.10.x or higher

# Verify Docker Compose is installed (1.29+)
docker-compose --version
# Expected output: Docker Compose version 1.29.x or higher

# Verify Git is installed
git --version
# Expected output: git version 2.x or higher

# Verify Linux kernel has TUN/TAP support
cat /proc/net/dev | grep -q tun && echo "✓ TUN module present" || echo "✗ TUN module missing"
# Expected: "✓ TUN module present"
```

### Network Requirements
```bash
# Verify no conflicts with Docker network (172.20.0.0/16)
ip route | grep -q 172.20.0.0 && echo "⚠ Network conflict detected" || echo "✓ No conflict"

# Check available ports (5000-9999 should be free)
netstat -tuln | grep -E "(7777|8805|2123|2152|36412|38412|9999)" | wc -l
# Expected: 0 (no ports in use)
```

### Repository Setup
```bash
# Verify you're in the correct directory
pwd
# Expected output should end with: .../oran-stack

# Verify git repository
git status
# Expected: "On branch webui" (or main if already merged)

# List key files to verify
ls -la Dockerfile.5gscore Dockerfile.webui docker-compose.yml .env | wc -l
# Expected: 4 files listed
```

---

## Test Phase 1: Infrastructure Setup

### Objective
Verify host system is configured for data plane networking before containers start.

### Test 1.1: Create TUN Interfaces
```bash
# Run the host TUN interface setup script
sudo ./setup-host-tun.sh

# Verify output includes:
# ✓ Creating TUN interface: ogstun
# ✓ Creating TUN interface: ogstun2
# ✓ Creating TUN interface: ogstun3
# ✓ All TUN interfaces created successfully

# Verify interfaces exist
ip link show | grep -E "ogstun[0-9]?"
# Expected: Three lines showing ogstun, ogstun2, ogstun3
```

**Pass Criteria**: All three TUN interfaces created and visible in `ip link show`

### Test 1.2: Verify TUN Interface Configuration
```bash
# Check IPv4 addresses on TUN interfaces
ip -4 addr show ogstun
# Expected: 10.45.0.1/16

ip -4 addr show ogstun2
# Expected: 10.46.0.1/16

ip -4 addr show ogstun3
# Expected: 10.47.0.1/16

# Check IPv6 addresses
ip -6 addr show ogstun | grep "2001:db8:cafe"
# Expected: 2001:db8:cafe::1/48 (with global scope)
```

**Pass Criteria**: All TUN interfaces have correct IPv4 and IPv6 addresses

### Test 1.3: Verify Docker Network
```bash
# List Docker networks
docker network ls | grep 5g-core-network
# Expected: One entry for "5g-core-network"

# Inspect the network
docker network inspect 5g-core-network
# Expected output should show:
# - Subnet: 172.20.0.0/16
# - Driver: bridge
# - Connected containers (will be empty before starting containers)
```

**Pass Criteria**: Docker network `5g-core-network` exists with correct subnet

---

## Test Phase 2: Container Deployment

### Objective
Verify all 18 containers build and start successfully.

### Test 2.1: Build Docker Images
```bash
# Build the main 5G core image (this takes 5-10 minutes)
docker-compose build 5g-core-nrf

# Monitor the build output
# Expected: Dockerfile.5gscore builds successfully with stages:
# - FROM ubuntu:22.04
# - apt-get install packages
# - git clone open5gs
# - ./configure && make && make install

# Build the WebUI image (this takes 5-15 minutes)
docker-compose build 5g-core-webui

# Monitor output:
# Expected: Dockerfile.webui builds with:
# - builder stage: Node 20 → npm ci → npm run build
# - runtime stage: Node 20 → copies built app → npm start
```

**Pass Criteria**: Both images build without errors. Check:
```bash
docker images | grep -E "(5g-core|open5gs-webui)"
# Expected: Two images listed with latest tag
```

### Test 2.2: Start All Containers
```bash
# Start the deployment
docker-compose up -d

# Monitor startup progress
docker-compose logs -f

# Expected log sequence (watch for 30-60 seconds):
# 1. mongodb: "mongod" started, "waiting for connections"
# 2. 5g-core-hss: open5gs-hssd initialization
# 3. 5g-core-nrf: NRF registration
# 4. 5g-core-amf: AMF startup messages
# 5. 5g-core-webui: "npm" "start" (after a few seconds)

# Press Ctrl+C after seeing startup messages (containers keep running in background)
```

**Pass Criteria**: Containers start without immediate failures

### Test 2.3: Wait for Startup Completion
```bash
# Monitor container health status
docker-compose ps

# Expected output format:
# NAME                      COMMAND                  SERVICE              STATUS                   PORTS
# 5g-core-amf               ...                      5g-core-amf          Up 15 seconds (healthy)  ...
# 5g-core-ausf              ...                      5g-core-ausf         Up 15 seconds (healthy)  ...
# ... (all containers)

# Wait for all containers to show "Up X seconds (healthy)"
# This typically takes 30-60 seconds
# You can wait with:
sleep 45 && docker-compose ps

# Verify all containers are running
docker-compose ps | grep -c "Up.*healthy"
# Expected: 18 (all containers healthy)
```

**Pass Criteria**: All 18 containers report "healthy" status

---

## Test Phase 3: NF Health & Connectivity

### Objective
Verify network functions started correctly and can communicate.

### Test 3.1: Check Container Logs for Errors
```bash
# Check for startup errors in each NF
# Look for "error", "failed", "exception" in lowercase

# Check 5G core NFs
for nf in nrf scp amf smf upf ausf udm pcf nssf bsf udr; do
  echo "=== Checking 5g-core-${nf} ==="
  docker-compose logs 5g-core-${nf} | grep -i error | head -3
done

# Check 4G NFs
for nf in hss mme sgwc sgwu pcrf; do
  echo "=== Checking 5g-core-${nf} ==="
  docker-compose logs 5g-core-${nf} | grep -i error | head -3
done

# Expected: Minimal/no error messages (some warnings are normal)
```

**Pass Criteria**: No critical errors in startup logs. Warning messages are acceptable.

### Test 3.2: Verify NRF Registration (Service Discovery)
```bash
# NRF is the service discovery function - all NFs should register with it
docker-compose logs 5g-core-nrf | grep -E "(register|binding|deregister)" | tail -20

# Expected output showing NF registrations like:
# [nrf] nf_register() ...
# [nrf] smf_register() ...
# [nrf] upf_register() ...
# etc.

# Alternatively, check if NRF is responding on port 7777
docker-compose exec 5g-core-nrf curl -s http://localhost:7777/nnrf-nfm/v1/nf-instances | jq '.nfInstances | length'
# Expected: Numeric output (number of registered NFs, typically 10+)
```

**Pass Criteria**: NRF shows registered NF instances

### Test 3.3: Verify MongoDB Connectivity
```bash
# Check MongoDB startup and data initialization
docker-compose logs mongodb | grep -E "(ready to accept|admin.*initialized|inserted)"

# Expected: Messages showing MongoDB is ready and data inserted

# Verify databases were created
docker-compose exec mongodb mongosh --eval "db.adminCommand('listDatabases')"
# Expected output should list:
# - admin
# - open5gs

# Verify sample subscribers exist
docker-compose exec mongodb mongosh open5gs --eval "db.subscribers.countDocuments()"
# Expected: 2 (the two test subscribers from init-webui-data.js)
```

**Pass Criteria**: MongoDB initialized with open5gs database and 2 test subscribers

### Test 3.4: Check SMF Configuration
```bash
# SMF manages sessions - verify it's configured correctly
docker-compose logs 5g-core-smf | grep -i "subnet\|smf_subnet\|10.45" | head -5

# Expected: Log entries referencing the subnet configuration

# Verify SMF config file was generated with correct PLMN
docker-compose exec 5g-core-smf grep -A5 "plmn:" /open5gs/install/etc/open5gs/smf.yaml

# Expected output showing:
# plmn:
#   - mcc: 001
#     mnc: 01
```

**Pass Criteria**: SMF correctly initialized with PLMN 001/01

### Test 3.5: Verify Data Plane Setup
```bash
# Check if UPF has proper IP forwarding
docker-compose exec 5g-core-upf sysctl net.ipv4.ip_forward
# Expected: net.ipv4.ip_forward = 1

# Verify TUN interface is accessible from UPF container
docker-compose exec 5g-core-upf ping -c 1 10.45.0.1
# Expected: "1 packets transmitted, 1 received" (0% loss)

# Check GTP-U listener (User Plane)
docker-compose exec 5g-core-upf netstat -tuln | grep 2152
# Expected: Line showing "0.0.0.0:2152" in LISTEN state
```

**Pass Criteria**: UPF has IP forwarding enabled and GTP-U port listening

---

## Test Phase 4: WebUI Functionality

### Objective
Verify WebUI is accessible and functional for subscriber management.

### Test 4.1: Check WebUI Container Health
```bash
# Verify WebUI container is running and healthy
docker-compose ps 5g-core-webui

# Expected: Status should show "Up X seconds (healthy)"

# Check WebUI logs for startup messages
docker-compose logs 5g-core-webui | tail -20

# Expected: Lines showing:
# "Server running on" or similar
# No fatal errors
```

**Pass Criteria**: WebUI container is healthy

### Test 4.2: Verify WebUI HTTP Response
```bash
# Test HTTP connectivity to WebUI
curl -s -o /dev/null -w "%{http_code}" http://localhost:9999/

# Expected output: 200 (OK)

# If 200, continue to next test
# If not 200, wait 10 more seconds and retry:
sleep 10
curl -s -o /dev/null -w "%{http_code}" http://localhost:9999/
```

**Pass Criteria**: WebUI responds with HTTP 200

### Test 4.3: Verify WebUI MongoDB Connection
```bash
# Check if WebUI can connect to MongoDB
docker-compose logs 5g-core-webui | grep -i "mongodb\|database\|connected" | head -5

# Expected: Messages showing successful MongoDB connection

# Verify WebUI database is populated
docker-compose exec mongodb mongosh open5gs --eval "db.administrators.findOne()" | grep admin

# Expected: Document with username "admin"
```

**Pass Criteria**: WebUI connected to MongoDB with admin user

### Test 4.4: Manual WebUI Access (Browser Test)
```bash
# From your local machine with web browser access:
# Navigate to: http://localhost:9999/

# Expected: Open5GS WebUI login page loads
# Login with:
#   Username: admin
#   Password: 1423

# After login, expected features:
# - Dashboard showing network statistics
# - Subscribers menu with 2 test subscribers visible
# - Can view/edit subscriber details
# - Can manage security keys (K, OPc, etc.)
```

**Pass Criteria**: WebUI login succeeds and dashboard displays

### Test 4.5: Verify Subscriber Data in WebUI
```bash
# Command-line verification (without browser)
# Check if subscribers are accessible via API

docker-compose exec 5g-core-webui curl -s http://localhost:3000/api/subscribers 2>/dev/null | head -20

# Expected: JSON response containing subscriber data

# Or directly query MongoDB
docker-compose exec mongodb mongosh open5gs --eval "db.subscribers.find().pretty()" | head -30

# Expected: Two subscriber documents with:
# - IMSI: 999700000000001, 999700000000002
# - Security info (K, OPc, AMF)
# - Profile (APNs, QoS, etc.)
```

**Pass Criteria**: Test subscribers exist and are queryable

---

## Test Phase 5: Data Plane Configuration

### Objective
Set up host-level networking to enable UE data connectivity.

### Test 5.1: Enable Network Forwarding
```bash
# Run the network forwarding setup script
sudo ./setup-host-network.sh

# Expected output:
# ✓ Enabling IPv4 forwarding
# ✓ Enabling IPv6 forwarding
# ✓ Configuring IPv4 NAT for ogstun
# ✓ Configuring IPv6 NAT for ogstun
# ✓ Configuring firewall rules
# ✓ Data plane network configuration complete

# Verify IPv4 forwarding is enabled
sudo sysctl net.ipv4.ip_forward
# Expected: net.ipv4.ip_forward = 1

# Verify IPv6 forwarding is enabled
sudo sysctl net.ipv6.conf.all.forwarding
# Expected: net.ipv6.conf.all.forwarding = 1
```

**Pass Criteria**: IPv4 and IPv6 forwarding enabled

### Test 5.2: Verify iptables NAT Rules
```bash
# Check IPv4 NAT rules for TUN subnets
sudo iptables -t nat -L -n | grep -E "10\.45|10\.46|10\.47"

# Expected: Multiple MASQUERADE rules for each TUN subnet

# Check IPv6 NAT rules
sudo ip6tables -t nat -L -n | grep -E "2001:db8"

# Expected: Multiple MASQUERADE rules for IPv6 subnets

# Sample output format:
# MASQUERADE all -- 10.45.0.0/16 0.0.0.0/0
# MASQUERADE all -- 10.46.0.0/16 0.0.0.0/0
# etc.
```

**Pass Criteria**: NAT rules present for all TUN subnets

### Test 5.3: Verify Firewall Configuration
```bash
# Check if UFW is disabled (as set by setup-host-network.sh)
sudo ufw status

# Expected: "Status: inactive" or similar disabled message

# If still active, check if Docker rules are present
sudo iptables -L DOCKER-USER -v 2>/dev/null | head -5

# These should allow traffic between Docker and host
```

**Pass Criteria**: Firewall not blocking Docker ↔ host traffic

### Test 5.4: Test TUN Interface Connectivity
```bash
# Ping from host through TUN interface to Docker subnet
ping -c 3 172.20.0.5 (this is AMF IP)
# Expected: 3 replies received (or at least 1)

# Ping the TUN interface itself (gateway)
ping -c 3 10.45.0.1
# Expected: 3 replies received

# Test DNS resolution (if needed for later)
getent hosts 5g-core-upf
# Expected: Shows 172.20.0.7 (or similar)
```

**Pass Criteria**: Host can ping TUN gateway and Docker IPs

---

## Test Phase 6: End-to-End Validation

### Objective
Verify the entire system is production-ready.

### Test 6.1: Comprehensive Container Health Check
```bash
# Create a comprehensive health report
echo "=== 5G Core Network Health Report ===" > health-report.txt
echo "Timestamp: $(date)" >> health-report.txt
echo "" >> health-report.txt

docker-compose ps >> health-report.txt
echo "" >> health-report.txt

echo "=== Container Health Statuses ===" >> health-report.txt
docker-compose exec 5g-core-nrf curl -s http://localhost:7777/nnrf-nfm/v1/nf-instances 2>/dev/null | jq '.nfInstances | length' >> health-report.txt

echo "=== MongoDB Status ===" >> health-report.txt
docker-compose exec mongodb mongosh --eval "db.adminCommand('ping')" >> health-report.txt

echo "=== WebUI Status ===" >> health-report.txt
curl -s -o /dev/null -w "HTTP Status: %{http_code}\n" http://localhost:9999/ >> health-report.txt

cat health-report.txt
```

**Pass Criteria**: Report shows all containers healthy and services responding

### Test 6.2: Stress Test - Restart All Containers
```bash
# Test that all containers can restart cleanly
docker-compose restart

# Wait for restart
sleep 30

# Verify all containers restarted successfully
docker-compose ps | grep -c "Up.*healthy"
# Expected: 18

# Check for any new errors in logs
docker-compose logs 5g-core-amf | grep -i error | tail -3
# Expected: No new errors
```

**Pass Criteria**: All containers restart successfully without errors

### Test 6.3: Configuration Change Verification
```bash
# Test that environment variables are properly injected
# Change a non-critical parameter and restart

# Edit .env temporarily
# (backup first)
cp .env .env.backup

# Change log level to debug (temporarily)
sed -i 's/LOG_LEVEL=info/LOG_LEVEL=debug/' .env

# Rebuild and restart one NF
docker-compose up -d 5g-core-ausf

# Wait for restart
sleep 10

# Verify the config was applied
docker-compose exec 5g-core-ausf grep -i "log.*level\|log_level" /open5gs/install/etc/open5gs/ausf.yaml | head -3

# Expected: Should reflect debug level

# Restore original config
mv .env.backup .env
docker-compose up -d 5g-core-ausf
```

**Pass Criteria**: Config changes apply without rebuild

### Test 6.4: Performance Baseline
```bash
# Record baseline metrics
echo "=== Performance Baseline ===" > metrics-baseline.txt

# CPU and Memory usage
docker stats --no-stream >> metrics-baseline.txt

# Network connections
netstat -tun | grep ESTABLISHED | wc -l >> metrics-baseline.txt

# MongoDB query performance (should be <100ms)
docker-compose exec mongodb sh -c 'time mongosh open5gs --eval "db.subscribers.findOne()"' >> metrics-baseline.txt

cat metrics-baseline.txt

# Save this for comparison against future testing
echo "Baseline recorded at: $(date)" >> metrics-baseline.txt
```

**Pass Criteria**: Baseline metrics recorded (no performance issues evident)

### Test 6.5: Log Output Validation
```bash
# Collect logs for analysis
docker-compose logs > deployment-logs.txt

# Check log sizes (ensure no excessive logging)
ls -lh deployment-logs.txt
# Expected: File size < 100MB for normal operation

# Search for critical patterns
grep -i "fatal\|panic\|segmentation" deployment-logs.txt
# Expected: No results (or very few)

# Check for successful startup of critical NFs
grep -i "started\|listening\|registered" deployment-logs.txt | wc -l
# Expected: 20+ lines (indicating multiple successful startups)
```

**Pass Criteria**: Logs show clean startup with no critical errors

---

## Troubleshooting Test Failures

### Symptom: Containers won't start
```bash
# Check Docker daemon
docker ps
# If fails: systemctl restart docker

# Check disk space
df -h /
# If <5GB: clean up old images/volumes
docker system prune -a

# Check for port conflicts
netstat -tuln | grep -E "7777|8805|2123|2152"
# If ports in use: stop conflicting services or change ports in .env

# Rebuild from scratch
docker-compose down -v  # ⚠️ WARNING: Deletes all data
docker-compose build --no-cache
docker-compose up -d
```

### Symptom: Containers start but show "unhealthy"
```bash
# Check specific container health
docker inspect 5g-core-nrf | grep -A 10 '"Health"'

# View detailed logs
docker-compose logs 5g-core-nrf

# Common causes:
# 1. Port binding failed: port already in use
# 2. MongoDB not ready: wait longer before restart
# 3. Network not ready: verify Docker network exists

# Solution:
docker-compose down
docker-compose up -d
sleep 60  # Longer wait
docker-compose ps
```

### Symptom: WebUI not accessible
```bash
# Check WebUI container
docker-compose ps 5g-core-webui

# Check WebUI logs
docker-compose logs 5g-core-webui | tail -30

# Verify MongoDB connection
docker-compose exec 5g-core-webui curl -s mongodb:27017
# If fails: MongoDB not accessible, check MongoDB container

# Verify port mapping
docker-compose port 5g-core-webui 9999
# Expected: 0.0.0.0:9999

# Try manual connection
docker-compose exec 5g-core-webui curl -s http://localhost:9999/ | head -20
```

### Symptom: Data plane not working
```bash
# Check TUN interfaces
ip link show | grep ogstun
# If not found: run setup-host-tun.sh again

# Check forwarding
sudo sysctl net.ipv4.ip_forward
# If not 1: run setup-host-network.sh again

# Check NAT rules
sudo iptables -t nat -L -n | grep MASQUERADE
# If not present: run setup-host-network.sh again

# Test connectivity
ping -c 1 10.45.0.1
# If fails: check TUN interface configuration
```

### Symptom: MongoDB initialization failed
```bash
# Check MongoDB logs
docker-compose logs mongodb | tail -30

# Verify MongoDB is responsive
docker-compose exec mongodb mongosh --eval "db.version()"
# Should return version number

# Re-initialize data
docker-compose exec mongodb mongosh < init-webui-data.js

# Or restart MongoDB completely
docker-compose restart mongodb
sleep 10
docker-compose logs mongodb | grep "ready\|initialized"
```

---

## Test Report Template

Use this template to document your test results:

```markdown
# 5G Core Deployment Test Report

**Date**: _______________
**Tester**: _______________
**Environment**: Linux ________, Docker ________, Compose ________

## Pre-Deployment Checklist
- [ ] CPU cores: ________ (≥4 required)
- [ ] RAM: ________ (≥8GB required)
- [ ] Disk space: ________ (≥50GB required)
- [ ] TUN/TAP support verified
- [ ] No port conflicts

## Test Phase 1: Infrastructure Setup
- [ ] TUN interfaces created (ogstun, ogstun2, ogstun3)
- [ ] TUN IPv4 addresses correct (10.45.x.x, 10.46.x.x, 10.47.x.x)
- [ ] TUN IPv6 addresses correct (2001:db8:cafe::, etc.)
- [ ] Docker network created (172.20.0.0/16)

## Test Phase 2: Container Deployment
- [ ] 5G core image builds successfully
- [ ] WebUI image builds successfully
- [ ] All 18 containers start
- [ ] All containers reach "healthy" status within 2 minutes

## Test Phase 3: NF Health & Connectivity
- [ ] No critical errors in startup logs
- [ ] NRF shows registered NF instances (10+)
- [ ] MongoDB initialized with 2 test subscribers
- [ ] SMF configured with PLMN 001/01
- [ ] UPF has IP forwarding and GTP-U listener

## Test Phase 4: WebUI Functionality
- [ ] WebUI container is healthy
- [ ] WebUI responds with HTTP 200
- [ ] WebUI connected to MongoDB
- [ ] WebUI accessible at http://localhost:9999
- [ ] Login successful (admin/1423)
- [ ] Test subscribers visible in WebUI

## Test Phase 5: Data Plane Configuration
- [ ] setup-host-network.sh completes without errors
- [ ] IPv4 forwarding enabled (net.ipv4.ip_forward = 1)
- [ ] IPv6 forwarding enabled
- [ ] iptables NAT rules present
- [ ] Firewall not blocking traffic
- [ ] Host can ping TUN gateway (10.45.0.1)

## Test Phase 6: End-to-End Validation
- [ ] All containers healthy in final health check
- [ ] Containers restart cleanly
- [ ] Configuration changes apply correctly
- [ ] Baseline metrics recorded
- [ ] No fatal errors in logs

## Issues Encountered
```
[List any issues, workarounds, and resolutions]
```

## Summary
**Overall Status**: [ ] PASS [ ] PASS WITH MINOR ISSUES [ ] FAIL

**Notes**:
```
[Additional notes and observations]
```

**Approved for Production**: [ ] YES [ ] NO [ ] PENDING FIXES
```

---

## Next Steps After Testing

### If All Tests Pass ✅
1. Document the successful test in the report template
2. Back up any important logs: `docker-compose logs > successful-deployment-logs.txt`
3. Commit the test report to your repository
4. Proceed to production deployment with confidence
5. Consider running load testing for performance validation

### If Tests Fail ❌
1. Document the issue in detail
2. Check the Troubleshooting section above
3. Collect logs and error messages
4. Review the relevant test phase instructions
5. Make necessary fixes to code or configuration
6. Re-run the failing test phase only

### Ongoing Operations
```bash
# Monitor deployment health daily
docker-compose ps

# Check for new errors
docker-compose logs --tail=100 | grep -i error

# Create regular backups
docker-compose exec mongodb mongodump --out backup-$(date +%Y%m%d)

# Update subscriber data
# Use WebUI at http://localhost:9999/
```

---

**This testing guide ensures the 5G core network is ready for lab evaluation and production deployment.**
