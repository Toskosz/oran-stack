# Anomaly Detection System — Architecture and Integration Guide

## Overview

This document describes the **FHE-based Anomaly Detection System (ADS)** integrated into the oran-stack. The system ports the `oai-anomaly-detection` project from OpenAirInterface/FlexRIC to the O-RAN SC Near-RT RIC + Open5GS + srsRAN stack.

The system classifies per-flow traffic in real time using a **Fully Homomorphic Encryption (FHE)** RandomForest model, enabling privacy-preserving anomaly detection on UPF traffic without exposing plaintext flow features.

---

## Architecture

```
┌──────────────────────────────────────────────────────────────────────────┐
│                          oran-stack xApp Pipeline                        │
│                                                                          │
│  UPF1 (ogstun / 10.45.0.0/16)                                           │
│  ┌────────────┐   sniff    ┌─────────────────┐                          │
│  │ads-slice1  │ ─────────► │                 │                          │
│  │(sidecar)   │  TCP:8080  │   xapp-kpi      │                          │
│  └────────────┘            │                 │                          │
│  network_mode:             │  • Preprocessor │   Redis Stream           │
│  service:5g-core-upf       │  • FHE encrypt  │ ──xapp:messages──►      │
│                            │  • FHE decrypt  │                          │
│  UPF2 (ogstun2 / 10.46.0/16)│                │ ◄──────────────────     │
│  ┌────────────┐   sniff    │                 │                          │
│  │ads-slice2  │ ─────────► │                 │                          │
│  │(sidecar)   │  TCP:8080  └─────────────────┘                          │
│  └────────────┘                    ▲                                    │
│  network_mode:                     │ Redis Stream                       │
│  service:5g-core-upf2              │ xapp:messages                      │
│                                    │                                    │
│                            ┌───────┴────────────┐                       │
│                            │  xapp-inference    │                       │
│                            │  • FHEModelServer  │                       │
│                            │  • runs() on enc.  │                       │
│                            │    input blob      │                       │
│                            └────────────────────┘                       │
│                                                                          │
│   Redis Stream (ric-dbaas)                                               │
│   ──────────────────────────────────────────────────────────────────►   │
│                            ┌────────────────────┐                       │
│                            │    xapp-rc         │                       │
│                            │  • sliding window  │                       │
│                            │  • PRB control     │──► E2SM-RC ──► DU    │
│                            └────────────────────┘                       │
└──────────────────────────────────────────────────────────────────────────┘
```

---

## Components

### `ads-slice1` / `ads-slice2` — ADS Sidecars

- **Image**: `xapp-ads:latest` (built from `xapps/ads/`)
- **Source**: Ported from `oai-anomaly-detection/ads-slice1.py` and `ads-slice2.py`
- **Network**: Shares UPF network namespace (`network_mode: service:5g-core-upf[2]`)
- **Function**: Sniffs IP packets on the UPF TUN interface, extracts flow features (protocol, service, byte counts), and streams JSON records to `xapp-kpi` via TCP

**Key changes from original:**
- Single parameterised image (`ADS_SST`, `ADS_SD`, `ADS_SUBNET`, `ADS_IFACE` env vars)
- Fixed subnet filters: `12.1.1.0/24` → `10.45.0.0/16` / `10.46.0.0/16`
- Fixed server target: `192.168.70.1:8080` → `xapp-kpi:8080`
- Reconnection loop handles multi-connection scenarios
- `network_mode: service:` instead of running inside OAI UPF container

### `xapp-kpi` — FHE KPI Preprocessor

- **Image**: `xapp-kpi:latest` (built from `xapps/kpi/`)
- **Source**: Ported from `oai-anomaly-detection/xapp_enc_kpi.py`
- **Network**: `ric-network` at `172.22.0.220`
- **Function**: TCP server for ADS; applies sklearn preprocessor (OneHotEncoder + scaler), encrypts with `FHEModelClient.quantize_encrypt_serialize()`, publishes to Redis Stream with `status=0`. Second thread decrypts `status=1` entries, computes anomaly flag, sets `status=2`

**Key fixes from original:**
- Fixed single-connection bug (`listen(1)` + single `accept()`) → multi-threaded accept loop
- Replaced SQLite with Redis Streams
- Connection target changed from TCP client to TCP server

### `xapp-inference` — FHE Server-Side Inference

- **Image**: `xapp-inference:latest` (built from `xapps/inference/`)
- **Source**: Ported from `oai-anomaly-detection/xapp_inference.py`
- **Network**: `ric-network` at `172.22.0.221`
- **Function**: Polls Redis Stream for `status=0` entries, runs `FHEModelServer.run()` with the encrypted input and evaluation keys, writes encrypted output, sets `status=1`

### `xapp-rc` — RC Slice Controller

- **Image**: `xapp-rc:latest` (built from `xapps/rc/`)
- **Source**: Ported from `oai-anomaly-detection/xapp_rc_slice_ctrl.c`
- **Network**: `ric-network` at `172.22.0.222`
- **Language**: Go (replaces C/FlexRIC)
- **Function**: Reads Redis Stream (last 30 `status=2` entries per slice), computes per-slice anomaly ratio, issues E2SM-RC `Slice_level_PRB_quota` control messages to srsRAN DU

**PRB quota policy:**
| Anomaly ratio | PRB quota |
|---|---|
| 100% | 0 (hard throttle) |
| > 50% (configurable) | 25 |
| ≤ 50% | 50 (default) |

**Note on RRC Release:** The original C xApp used the OAI telnet backdoor (`echo rrc release_rrc ... | nc IP 9090`) which is not available in srsRAN. The fallback is PRB=0, which prevents the DU from scheduling any uplink/downlink for the anomalous slice without requiring a protocol-level UE release.

---

## Redis Stream Schema

**Key**: `xapp:messages`

| Field | Type | Description |
|-------|------|-------------|
| `id` | auto (stream ID) | Auto-generated by `XADD` |
| `sst` | string | S-NSSAI SST value |
| `sd` | string | S-NSSAI SD value |
| `encrypted_input` | base64 string | FHE-encrypted flow features |
| `encrypted_prediction_result` | base64 string | FHE-encrypted inference output |
| `anomaly_percentage` | string | `"0"` or `"1"` |
| `status` | string | `"0"` pending / `"1"` inferred / `"2"` decrypted |
| `timestamp` | ISO-8601 string | Wall-clock time of flow capture |

**Inspect with:**
```bash
docker exec ric-dbaas redis-cli XRANGE xapp:messages - + COUNT 10
```

---

## FHE Model

- **Algorithm**: RandomForest with 2 estimators, depth 2 (deliberately tiny for FHE circuit feasibility)
- **Library**: [Concrete ML](https://github.com/zama-ai/concrete-ml) (Zama FHE)
- **Training data**: NSL-KDD99 dataset (network intrusion detection)
- **Preprocessing**: `preprocessor.pkl` — sklearn `ColumnTransformer` with `OneHotEncoder` for categoricals and `StandardScaler` for numerics
- **Assets location**: `xapps/model/`
  - `preprocessor.pkl`
  - `client.zip` — FHE client (key generation, encrypt/decrypt)
  - `server.zip` — FHE server (evaluation / inference)

The model dir path expected by `FHEModelClient`/`FHEModelServer` is `/model/fhe_model` (a directory containing the unzipped artifacts). The `xapp-kpi` and `xapp-inference` containers mount `xapps/model/` at `/model/` and the `MODEL_PATH` env var points to `/model/fhe_model`.

> **Note**: concrete-ml ≥ 1.4 `FHEModelClient(path)` and `FHEModelServer(path)` expect `path` to be a directory containing the extracted client/server zip contents. The zips must be extracted into `/model/fhe_model/` before the containers start. This is currently handled by copying the zips into the mount and relying on concrete-ml's internal extraction — verify on first run.

---

## Network Topology

```
5g-core-network (172.20.0.0/24):
  SMF1  172.20.0.4   → UPF1  172.20.0.7   (Slice 1: SST=1 SD=1, 10.45.0.0/16)
  SMF2  172.20.0.22  → UPF2  172.20.0.23  (Slice 2: SST=1 SD=5, 10.46.0.0/16)

ric-network (172.22.0.0/24):
  xapp-kpi        172.22.0.220
  xapp-inference  172.22.0.221
  xapp-rc         172.22.0.222
  ric-dbaas       172.22.0.214  (Redis 6, port 6379)
  ric-e2term      172.22.0.210  (SCTP 36421)
```

---

## Slice Configuration

Two S-NSSAIs are deployed:

| Slice | SST | SD | UPF subnet | SMF/UPF |
|-------|-----|----|------------|---------|
| Slice 1 (eMBB baseline) | 1 | 1 | 10.45.0.0/16 | 172.20.0.4 / 172.20.0.7 |
| Slice 2 (anomaly-watched) | 1 | 5 | 10.46.0.0/16 | 172.20.0.22 / 172.20.0.23 |

Both slices are advertised in:
- `configs/amf.yaml` — `plmn_support.s_nssai`
- `configs/nssf.yaml` — `sbi.client.nsi`
- `srsran/configs/du.yml` — `cell_cfg.slice`
- `init-webui-data.js` — subscriber slice array (IMSI `001010000000001`)

A dedicated second 5G subscriber (IMSI `001010000000003`) is registered for Slice 2 testing.

---

## Deployment

```bash
# Start full stack including xApps
./scripts/launch-all.sh

# Start xApps only (if core + RIC + CU/DU already running)
./scripts/launch-all.sh --xapps-only

# Monitor anomaly stream
docker exec ric-dbaas redis-cli XRANGE xapp:messages - + COUNT 20

# View xApp logs
docker logs xapp-kpi       -f
docker logs xapp-inference -f
docker logs xapp-rc        -f
```

---

## Limitations and Future Work

1. **xapp-rc E2SM-RC stub**: The `sendControl()` function in `xapps/rc/main.go` currently logs the PRB decision but does not yet send the actual ASN.1-encoded E2SM-RC control PDU. Completing this requires integrating `ric-app-lib-go` and implementing the `E2SM-RC SliceLevelPRBQuota` IE encoding.

2. **FHE model loading**: concrete-ml expects an extracted directory at `MODEL_PATH`. The current setup mounts `xapps/model/` and the zips must be extracted. A startup init container or entrypoint script may be needed.

3. **RRC Release**: srsRAN has no telnet backdoor equivalent. PRB=0 is used as a throttle but does not release UE context. E2SM-RC UE-level actions (if supported by the srsRAN build) could be used for a proper release.

4. **Evaluation keys**: The current architecture generates evaluation keys fresh on each `xapp-inference` container start. For production, these should be persisted and shared via Redis or a key-management service.
