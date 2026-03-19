# 5G Core Docker Compose Setup Guide

## Overview

This setup creates a containerized 5G core network with the following architecture:

- **MongoDB**: Shared database container for all Network Functions (NFs)
- **5G Core NF**: Open5GS container that can run individual network functions
- **Host TUN Interfaces**: Shared TUN interfaces (ogstun, ogstun2, ogstun3) for data plane traffic

## Quick Start

Get your 5G core running in 3 commands:

```bash
# 1. Start the docker-compose stack
docker-compose up -d

# 2. Enter the container
docker exec -it 5g-core-nf bash

# 3. Run a Network Function (inside container)
cd /open5gs
./install/bin/open5gs-amfd  # or open5gs-smfd, open5gs-upfd, etc.
```

**Note**: TUN interfaces (ogstun, ogstun2, ogstun3) are created automatically inside the container if needed.

### What's Running After Step 1?

- ✅ MongoDB on `localhost:27017` (accessible from host)
- ✅ 5G Core NF container with Open5GS and 17 network function executables
- ✅ Shared Docker network for inter-service communication
- ✅ MongoDB is accessible from container at `mongodb://mongodb:27017/open5gs`

### Next: Configure Your NF

Once inside the container, edit the configuration files and run your desired NF:

```bash
# List available configurations
ls install/etc/open5gs/

# Edit configuration (optional)
nano install/etc/open5gs/amf.yaml

# Run AMF with configuration
./install/bin/open5gs-amfd -c install/etc/open5gs/amf.yaml
```

---

## Architecture

### Host-level TUN Strategy

The setup uses **Host TUN** interfaces, meaning:
1. TUN interfaces are created on the Docker **host** machine
2. Containers mount and access these interfaces via `/dev/net/tun`
3. All NF containers share the same TUN interfaces
4. This allows data plane traffic to flow between containers without complex routing

### Why Host TUN?

For a production 5G core:
- Multiple NFs (AMF, SMF, UPF, etc.) need to send/receive user plane traffic
- A single shared data plane (TUN) is more efficient than per-container TUN interfaces
- Matches typical 5G architectures where the UPF connects to a single virtual network
- Simplifies inter-NF communication

### Network Architecture

```
┌─────────────────────────────────────────────┐
│         Docker Host                         │
├─────────────────────────────────────────────┤
│                                             │
│  TUN Interfaces (host level):              │
│  ├─ ogstun    (10.45.0.1/16)               │
│  ├─ ogstun2   (10.46.0.1/16)               │
│  └─ ogstun3   (10.47.0.1/16)               │
│                                             │
│  Docker Network (5g-core-network):         │
│  ├─ 172.20.0.0/16                          │
│                                             │
│  ┌─────────────┐      ┌──────────────────┐ │
│  │  MongoDB    │      │  5G Core NF      │ │
│  │  Container  │◄────►│  Container       │ │
│  │  172.20.0.2 │      │  172.20.0.3      │ │
│  │  Port 27017 │      │  /dev/net/tun    │ │
│  └─────────────┘      └──────────────────┘ │
│                                             │
└─────────────────────────────────────────────┘
```

## Setup Instructions

### 1. Create TUN Interfaces on Host

```bash
sudo ./setup-host-tun.sh
```

This script:
- Creates TUN interfaces: ogstun, ogstun2, ogstun3
- Assigns IP addresses
- Makes them persistent for the current session

**Note**: TUN interfaces don't persist across reboots. You may want to add to:
- `/etc/network/interfaces` (Ubuntu/Debian)
- `/etc/sysconfig/network-scripts/` (CentOS/RHEL)
- Or use your system's network manager

### 2. Start the Docker Compose Stack

```bash
docker-compose up -d
```

This will:
1. Start MongoDB container (with health check)
2. Wait for MongoDB to be healthy
3. Start the 5G Core NF container
4. Create ogstun interfaces inside the container (if not on host)

### 3. Access the 5G Core Container

```bash
docker exec -it 5g-core-nf bash
```

Once inside:
- You have access to Open5GS installation at `/open5gs`
- You can run individual NF executables:
  - `./install/bin/open5gs-amfd` (AMF)
  - `./install/bin/open5gs-smfd` (SMF)
  - `./install/bin/open5gs-upfd` (UPF)
  - etc.
- MongoDB is accessible at `mongodb://mongodb:27017/open5gs`

### 4. Configure and Run a Specific NF

Example: Run the SMF (Session Management Function)

```bash
# Inside the container
cd /open5gs

# Edit configuration (if needed)
# nano install/etc/open5gs/smf.yaml

# Run SMF
./install/bin/open5gs-smfd -c install/etc/open5gs/smf.yaml
```

## Accessing MongoDB

### From the Host

```bash
mongosh mongodb://localhost:27017/open5gs
```

### From Inside a Container

```bash
# From inside 5g-core-nf container
mongosh mongodb://mongodb:27017/open5gs
```

## Environment Variables

The following environment variables are available in the 5G Core NF container:

- `SKIP_MONGODB`: Set to `"true"` to skip local MongoDB startup (uses external instance)
- `MONGODB_URI`: Connection string for MongoDB (default: `mongodb://mongodb:27017/open5gs`)

## Scaling to Multiple NF Containers

To run multiple NFs (one per container), create additional services in `docker-compose.yml`:

```yaml
  5g-core-amf:
    image: teste-core:latest
    container_name: 5g-core-amf
    depends_on:
      mongodb:
        condition: service_healthy
    environment:
      SKIP_MONGODB: "true"
    # ... rest of config (same as 5g-core)
    # Different port mappings if needed
    
  5g-core-smf:
    image: teste-core:latest
    container_name: 5g-core-smf
    depends_on:
      mongodb:
        condition: service_healthy
    environment:
      SKIP_MONGODB: "true"
    # ... rest of config
```

Then start them all:
```bash
docker-compose up -d
```

## Running Tests

### Prerequisites

Before running tests, ensure MongoDB replica set is initialized:

```bash
# The replica set is auto-initialized on first startup via init-mongodb.js script
# If needed, you can manually initialize it with:
docker exec 5g-mongodb mongosh --eval 'rs.initiate({_id: "rs0", members: [{_id: 0, host: "mongodb:27017", priority: 1}]})'
```

### Running Unit Tests

```bash
# Inside the container
docker exec 5g-core-nf bash -c "cd /open5gs && ./build/tests/unit/unit"
```

Expected output: `All tests passed.`

### Running Integration Tests

Tests that require MongoDB connection need the configuration file parameter:

```bash
# Inside the container - with explicit config file
docker exec 5g-core-nf bash -c "cd /open5gs && ./build/tests/transfer/transfer-error -c ./build/configs/sample.yaml"
```

### Important Note on MongoDB URI

The test configuration file (`sample.yaml`) has been updated to use the Docker service hostname:
- **Old (broken)**: `mongodb://localhost/open5gs` - localhost refers to the container itself
- **New (working)**: `mongodb://mongodb:27017/open5gs` - uses Docker network hostname

This change is automatically applied when building the Docker image. Tests should be run with the `-c` parameter to explicitly use this configuration file.

## Troubleshooting

### Container keeps exiting (exit code 2)

**Cause**: The entrypoint failed silently

**Solution**: 
- Check logs: `docker logs 5g-core-nf`
- The new entrypoint has error handling and won't exit on network setup failures
- It continues to bash even if TUN interfaces can't be created

### MongoDB connection refused in tests

**Cause**: 
1. Tests run without explicit config file parameter (uses default config with localhost)
2. MongoDB replica set not initialized

**Solution**:
- Always run tests with explicit config: `./build/tests/transfer/transfer-error -c ./build/configs/sample.yaml`
- Ensure MongoDB replica set is initialized (automatic on first startup)
- The compose file has `depends_on` with `service_healthy` condition
- MongoDB has a health check that takes ~30 seconds to pass
- If still failing, increase `start_period` in the health check

### Tests fail with "ogs_dbi_init failed"

**Cause**: The database initialization failed, typically due to:
1. MongoDB is not running or not healthy
2. Test is using wrong MongoDB URI (localhost instead of mongodb hostname)

**Solution**:
- Check MongoDB is healthy: `docker-compose ps` (should show MongoDB as healthy)
- Always pass explicit config file with `-c ./build/configs/sample.yaml`
- Verify MongoDB can be reached: `docker exec 5g-core-nf mongosh mongodb://mongodb:27017/open5gs`

### TUN interfaces not accessible from container

**Possible causes**:
1. TUN interfaces not created on host
   - Run: `sudo ./setup-host-tun.sh`
   - Verify: `ip tuntap list` (on host)

2. Container doesn't have `/dev/net/tun` access
   - Check docker-compose.yml has: `devices: [/dev/net/tun:/dev/net/tun]`
   - Ensure container has `privileged: true` or appropriate caps

3. Network namespace isolation
   - If using custom network driver, you may need `--net=host` (less isolated)

## Migration to Kubernetes

For Kubernetes deployment:

1. **ConfigMaps**: Store Open5GS configurations
2. **StatefulSet**: For MongoDB (or use managed database)
3. **Deployments**: One per NF (AMF, SMF, UPF, etc.)
4. **Services**: For inter-service communication
5. **NetworkPolicy**: For TUN/data plane access

The docker-compose setup is a good testing ground before K8s migration.

## Files Modified/Created

- `Dockerfile.5gscore`: Updated to fix MongoDB URI in sample.yaml (localhost → mongodb:27017)
- `entrypoint.sh`: Enhanced with better error handling and logging for network setup
- `docker-compose.yml`: Complete setup with MongoDB + 5G Core NF services with replica set initialization
- `init-mongodb.js`: MongoDB initialization script for automatic replica set setup
- `setup-host-tun.sh`: Script to create TUN interfaces on host

## Next Steps

1. ✅ Basic containerization working
2. ✅ MongoDB connectivity fixed for tests (URI updated from localhost → mongodb hostname)
3. ⏳ Integrate tests into CI/CD pipeline
4. ⏳ Configure multi-NF communication
5. ⏳ Add monitoring/logging (ELK stack, Prometheus)
6. ⏳ Prepare for Kubernetes deployment
