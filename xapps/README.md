# xApps — Anomaly Detection + RAN Slice Control

This directory contains five xApp containers that together form a closed-loop
anomaly detection and RAN slice control pipeline integrated with the
`oran-stack` (O-RAN SC Near-RT RIC + Open5GS + srsRAN).

---

## Overview

```
UE traffic
    │
    ▼
Open5GS UPF (ogstun / ogstun2)
    │  packet sniff (shared netns)
    ▼
ads-slice1 / ads-slice2     ── JSON flow features ──▶  xapp-kpi
                                                            │
                                              FHE encrypt, push Redis Stream
                                                            │
                                                        xapp-inference
                                              FHE server-side inference
                                                            │
                                              xapp-kpi decrypts result
                                                            │
                                                        xapp-rc
                                          sliding-window anomaly ratio
                                          → E2SM-RC PRB quota control
                                          → srsRAN DU via Near-RT RIC
```

**Message bus**: Redis Streams on `ric-dbaas` (`172.22.0.214:6379`).
Stream key: `xapp:messages`.

---

## Containers

### `ads-slice1` / `ads-slice2` — ADS Sidecar (`xapps/ads/`)

**Language**: Python 3.11 + Scapy

Run as sidecar containers that share the network namespace of the Open5GS
UPF containers (`network_mode: service:5g-core-upf[2]`). Each sidecar:

1. Sniffs IP packets on `ogstun` / `ogstun2` using a BPF subnet filter.
2. Extracts per-flow features (protocol, service, byte counts).
3. Sends a JSON line per flow over a persistent TCP connection to `xapp-kpi:8080`.

| Variable | Default | Description |
|---|---|---|
| `ADS_SST` | `1` | S-NSSAI SST for this slice |
| `ADS_SD` | `1` | S-NSSAI SD for this slice |
| `ADS_SUBNET` | `10.45.0.0/16` | BPF filter subnet |
| `ADS_IFACE` | `ogstun` | TUN interface to sniff |
| `KPI_HOST` | `xapp-kpi` | xapp-kpi hostname |
| `KPI_PORT` | `8080` | xapp-kpi TCP port |

The two sidecars are parameterised identically — only `ADS_SD`, `ADS_SUBNET`,
and `ADS_IFACE` differ between slice 1 (SD=1, `ogstun`) and slice 2
(SD=5, `ogstun2`).

---

### `xapp-kpi` — FHE KPI Processor (`xapps/kpi/`)

**Language**: Python 3.11 + concrete-ml 1.5.0
**IP**: `172.22.0.220`

TCP server (port 8080) for ADS sidecar connections. For each received flow
record it:

1. Applies the sklearn preprocessor (`preprocessor.pkl`).
2. Encrypts the input with `FHEModelClient.quantize_encrypt_serialize()`.
3. Publishes a `status=0` entry to the Redis Stream.

A second thread polls the stream for `status=1` entries (inference done),
decrypts them with `FHEModelClient.deserialize_decrypt_dequantize()`, sets
`anomaly_percentage` (0 or 1), and advances the entry to `status=2`.

**FHE key material**: `client.zip` (from `xapps/model/`) is extracted into
`/tmp/fhe_model/` at container startup by `entrypoint.sh`.

| Variable | Default | Description |
|---|---|---|
| `KPI_PORT` | `8080` | TCP listen port |
| `REDIS_HOST` | `ric-dbaas` | Redis hostname |
| `REDIS_PORT` | `6379` | Redis port |
| `MODEL_PATH` | `/tmp/fhe_model` | Extracted FHE model directory |
| `PREPROCESSOR` | `/model/preprocessor.pkl` | Preprocessor pickle path |
| `STREAM_KEY` | `xapp:messages` | Redis stream key |

---

### `xapp-inference` — FHE Server Inference (`xapps/inference/`)

**Language**: Python 3.11 + concrete-ml 1.5.0
**IP**: `172.22.0.221`

Polls the Redis Stream for `status=0` entries. For each entry:

1. Decodes the base64 `encrypted_input`.
2. Runs `FHEModelServer.run(enc_input, eval_keys)` — fully homomorphic inference.
3. Encodes the encrypted result and advances the entry to `status=1`.

Evaluation keys are generated once at startup from `FHEModelClient` and
reused for all inference calls.

Both `server.zip` and `client.zip` are extracted into `/tmp/fhe_model/` at
container startup by `entrypoint.sh`.

| Variable | Default | Description |
|---|---|---|
| `REDIS_HOST` | `ric-dbaas` | Redis hostname |
| `REDIS_PORT` | `6379` | Redis port |
| `MODEL_PATH` | `/tmp/fhe_model` | Extracted FHE model directory |
| `STREAM_KEY` | `xapp:messages` | Redis stream key |

---

### `xapp-rc` — RAN Slice Controller (`xapps/rc/`)

**Language**: Go 1.21
**IP**: `172.22.0.222`

Polls the Redis Stream every 5 seconds. Maintains a sliding window of the
last N=30 fully-processed (`status=2`) entries per slice and computes the
anomaly ratio. Sends an E2SM-RC `Slice_level_PRB_quota` control action
whenever the ratio changes:

| Anomaly ratio | PRB quota |
|---|---|
| 100 % (all anomalous) | 0 (hard throttle) |
| > 50 % (alert threshold) | 25 |
| ≤ 50 % | 50 (default) |

The PRB-quota decision is currently logged; the actual `ric-app-lib-go`
xApp registration + ASN.1-encoded E2SM-RC PDU is a **known stub** (see
`sendControl()` in `main.go`).

| Variable | Default | Description |
|---|---|---|
| `REDIS_ADDR` | `ric-dbaas:6379` | Redis address |
| `STREAM_KEY` | `xapp:messages` | Redis stream key |
| `WINDOW` | `30` | Sliding window size |
| `ALERT_THRESHOLD` | `0.5` | Anomaly ratio for 25-PRB alert |
| `POLL_INTERVAL` | `5` | Seconds between polls |

---

## FHE Model Assets (`xapps/model/`)

| File | Used by | Description |
|---|---|---|
| `client.zip` | xapp-kpi, xapp-inference | FHE client keys + parameters |
| `server.zip` | xapp-inference | FHE server evaluation circuit |
| `preprocessor.pkl` | xapp-kpi | sklearn preprocessor (OHE + scaler) |
| `entrypoint.sh` | — | Reference only (not used directly) |

The model is a tiny `RandomForestClassifier` (2 estimators, depth 2) compiled
with Concrete ML 1.5.0. It was trained on KDD-99-style network flow features.

---

## Redis Stream Schema

Stream key: `xapp:messages`

| Field | Type | Description |
|---|---|---|
| `sst` | string | S-NSSAI SST |
| `sd` | string | S-NSSAI SD |
| `encrypted_input` | base64 | FHE ciphertext from xapp-kpi |
| `encrypted_prediction_result` | base64 | FHE result from xapp-inference |
| `anomaly_percentage` | "0" or "1" | Decrypted anomaly flag |
| `status` | "0" / "1" / "2" | Pipeline stage |
| `timestamp` | ISO-8601 | Entry creation time |

**Status lifecycle**: `0` (pending inference) → `1` (inference done) → `2` (decryption done)

**Update pattern**: Redis Streams do not support in-place field updates.
All state transitions use `XDEL` (old entry) + `XADD` (new entry with updated fields).

---

## Bring-Up

The xApps are launched after the core stack and RIC are running:

```bash
# 1. Core network
docker compose -f docker-compose.yml up -d

# 2. Near-RT RIC
docker compose -f docker-compose.ric.yml up -d

# 3. xApps
docker compose -f docker-compose.xapps.yml up -d

# Or use the launch script (launches everything in order):
./scripts/launch-all.sh

# xApps only:
./scripts/launch-all.sh --xapps-only

# Take down xApps first (before --down):
./scripts/launch-all.sh --down
```

---

## Known Limitations

1. **`xapp-rc` E2SM-RC stub**: `sendControl()` in `xapps/rc/main.go` logs the
   decision but does not yet send an ASN.1-encoded E2SM-RC PDU to the RIC.
   Full `ric-app-lib-go` integration is required.

2. **RRC release not available**: The original OAI xApp used a telnet backdoor
   (`nc 9090`) to force RRC release on anomalous UEs. srsRAN does not expose
   this interface. PRB=0 throttle is used as a fallback.

3. **FHE performance**: The concrete-ml FHE inference is CPU-intensive (~seconds
   per sample). For production use, FHE inference should be offloaded to a
   dedicated server or the model compiled for FHE with a more optimised
   parameter set.
