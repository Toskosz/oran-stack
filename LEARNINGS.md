# O-RAN Stack Learnings

Accumulated debugging notes for the srsRAN + Open5GS + Near-RT RIC Docker stack.

---

## Part 1: 5G Core & srsRAN

---

## 1. Root Cause Chain (fully resolved)

### 1.1 `gettext-base` missing from Docker image

**Symptom:** `envsubst` not found; NF config templates were never processed at container start,
leaving all `${VAR}` placeholders as empty strings.

**Cause:** `Dockerfile.5gscore` listed `gettext-base` but the image in use pre-dated that line
(built March 19 before the change, or the layer was cached before the fix).

**Fix:** Rebuild `teste-core:latest` image.
```
docker build -f Dockerfile.5gscore -t teste-core:latest .
```

---

### 1.2 `x-open5gs-common-env` anchor missing NF IP/port variables

**Symptom:** Even after fixing `envsubst`, env vars like `AMF_IP`, `NRF_IP`, `SCP_IP`, `SEPP_IP`
expanded to empty strings inside containers.

**Cause:** `docker-compose.yml`'s `x-open5gs-common-env` YAML anchor listed only a few vars.
The full set of NF addresses/ports existed in `.env` but was not passed through to containers.

**Fix:** Add all missing vars to `x-open5gs-common-env` in `docker-compose.yml`:
```
AMF_IP, AMF_SBI_PORT, AMF_NGAP_PORT, AMF_METRICS_PORT,
NRF_IP, NRF_SBI_PORT, SCP_IP, SCP_SBI_PORT, SEPP_IP
```

---

### 1.3 NF config templates incompatible with Open5GS v2.7.7

The `configs/*.yaml` templates were written for an older Open5GS API. v2.7.7 introduced
several breaking changes.

#### 1.3.1 AMF — missing required fields

**Error:** AMF started but NRF rejected registration with `NFProfile has no usable endpoint`.

**Fix (applied):** Add to `configs/amf.yaml`:
```yaml
amf_name: open5gs-amf0
network_name:
  full: Open5GS
time:
  t3512:
    value: 540
```

#### 1.3.2 SMF — `gtp` key renamed; PFCP UPF uses `address` not `uri`

**Error:**
```
WARNING: unknown key `gtp`
ERROR: No smf.gtpu.address
```
**Fix (applied):** Replace `gtp:` with split `gtpc:` + `gtpu:` blocks, and change PFCP UPF
entry from `uri: http://...` to `address: ... / port: ...`:
```yaml
pfcp:
  client:
    upf:
      - address: 172.20.0.7
        port: 8805
gtpc:
  server:
    - address: 172.20.0.4
      port: 2123
gtpu:
  server:
    - address: 172.20.0.4
      port: 2152
```

#### 1.3.3 NSSF — `nssai_supported` key removed; requires `sbi.client.nsi`

**Error:**
```
WARNING: unknown key `nssai_supported`
ERROR: No nssf.nsi
```
**Fix (applied):** Replace top-level `nssai_supported` with `nsi` under `sbi.client`:
```yaml
sbi:
  client:
    nsi:
      - uri: http://172.20.0.10:7777
        s_nssai:
          sst: 1
```

#### 1.3.4 SEPP — undefined env vars for inter-PLMN peers; missing NRF client; wrong N32 key

**Errors:**
1. `${SEPP_N32F_PEER_URI}` and `${SEPP_N32_PEER_URI}` are not defined in `.env`.
2. `Both NRF and SCP are unavailable` — no `nrf` client in SEPP config.
3. `No n32.server.sender` — wrong section key (`n32f` → `n32`) and missing `sender` field.
4. `Address already in use` — SBI and N32 servers must use different ports (7777 vs 7778).

**Fix (applied):** For a single-operator lab, remove inter-PLMN peer entries entirely.
Add NRF/SCP clients. Use `n32:` with `sender: <MCC><MNC>` and a distinct port (7778):
```yaml
sepp:
  sbi:
    server:
      - address: ${SEPP_IP}
        port: 7777
    client:
      nrf:
        - uri: http://${NRF_IP}:${NRF_SBI_PORT}
      scp:
        - uri: http://${SCP_IP}:${SCP_SBI_PORT}
  n32:
    server:
      - sender: ${MCC}${MNC}
        address: ${SEPP_IP}
        port: 7778
```

#### 1.3.5 SCP — missing NRF client (root cause of all NRF HTTP 500 errors)

**Symptom:** All NFs (AMF, AUSF, UDM, PCF, BSF, UDR) returned `HTTP 500` on NRF registration.
NRF log showed `NFProfile has no usable endpoint` for every registration attempt.

**Root Cause:** Open5GS v2.7.7 uses `DELEGATED_AUTO` mode by default — NFs route SBI
requests through the SCP. The SCP had no `nrf.client` configured, so it responded with
`No NRF` and returned 500 to all forwarded registration requests.

**Fix (applied):** Add `sbi.client.nrf` to `configs/scp.yaml`:
```yaml
scp:
  sbi:
    server:
      - address: 172.20.0.200
        port: 7777
    client:
      nrf:
        - uri: http://172.20.0.10:7777
```

#### 1.3.6 Logger format changed

**Warning (non-fatal):** All NFs warn on startup:
```
Please change the configuration file as below.
<OLD>  logger: file: /var/log/open5gs/xxx.log
<NEW>  logger: file: path: /var/log/open5gs/xxx.log
```
**Fix (applied):** Updated all `configs/*.yaml` with:
```yaml
logger:
  file:
    path: /var/log/open5gs/xxx.log
  level: ${LOG_LEVEL}
```

#### 1.3.7 `global.pool.packet` key removed (non-fatal)

**Warning:** `unknown key 'packet'` on all NFs. The `global.pool.packet: 32768` entry is
no longer a recognised key in v2.7.7. It is harmless but can be removed.

---

## 2. srsRAN UE (`srsue`) Image Issues

### 2.1 `libpcsclite.so.1` missing from runtime stage

**Error:** `error while loading shared libraries: libpcsclite.so.1`

**Cause:** `libpcsclite-dev` was in the builder stage only. The runtime stage did not
install `libpcsclite1`.

**Fix:** Add `libpcsclite1` to the runtime apt-get install block in `Dockerfile.srsue`.

### 2.2 `libsrsran_rf.so.0` not found at runtime

**Error:** `error while loading shared libraries: libsrsran_rf.so.0`

**Cause:** srsRAN 4G builds shared RF-plugin libraries throughout the build tree. The
Dockerfile's `COPY --from=builder /opt/srsRAN_4G/build/lib/ /usr/local/lib/srsran4g/`
was either copying an empty dir or `ldconfig` didn't pick up the path.

**Fix:** Use a bind mount to find and copy ALL `.so` files from the build tree:
```dockerfile
RUN --mount=type=bind,from=builder,source=/opt/srsRAN_4G/build,target=/srsran-build \
    find /srsran-build -name "*.so*" -exec cp -P {} /usr/local/lib/ \; && ldconfig
```

### 2.3 `unrecognised option 'gw.tun_dev_name'`

**Error:** `unrecognised option 'gw.tun_dev_name'` (non-fatal warning; causes crash in
some srsRAN 4G versions if treated as fatal).

**Fix:** Remove `tun_dev_name = tun_srsue` from `[gw]` section in `srsran/configs/ue.conf`.

---

## 3. srsRAN DU crashing on E2AP failure

**Symptom:** DU repeatedly restarts with:
```
E2AP: Failed to connect to RIC on 172.22.0.210:36421. error="Connection refused"
```

**Cause:** `e2.enable_du_e2: true` is set but the RIC (`ric-e2term`) container is down.
E2AP connection failure is treated as fatal by this srsRAN build.

**Fix:** Disable E2 in `srsran/configs/du.yml` when RIC is not available:
```yaml
e2:
  enable_du_e2: false
```
Re-enable when the RIC is operational.

---

## 4. Confirmed Working State

After all fixes above:

| Component | Status |
|---|---|
| MongoDB | Up (healthy) |
| NRF | Up — serving `nnrf-nfm`, `nnrf-disc` |
| SCP | Up — forwarding NF requests to NRF |
| AMF | Up — NGAP on `172.20.0.5:38412`; NRF registered |
| SMF | Up — NRF registered |
| UPF | Up |
| AUSF | Up — NRF registered |
| UDM | Up — NRF registered |
| PCF | Up — NRF registered |
| BSF | Up — NRF registered |
| UDR | Up — NRF registered |
| NSSF | Up — NRF registered |
| SEPP | Up — NRF registered |
| srs_cu | Up — gNB N2 accepted by AMF (`gNB-N2 accepted[172.20.0.50]`) |
| srs_du | Up — F1-C to CU-CP established |
| srsue | Up — ZMQ sockets connected to DU; performing NR cell search |

Still crashing (4G EPC — not needed for 5G SA lab):
- `5g-core-mme`, `5g-core-hss`, `5g-core-pcrf` — crash on startup with signal 139/255

RIC bootstrap issues (timing race, keep-alive timers, rtmgr config) fully resolved — see Part 2.

---

## 5. Key Architecture Notes

### NF Communication in v2.7.7 (`DELEGATED_AUTO` mode)
- All NF SBI requests go through the **SCP** by default.
- The SCP must have a `nrf` client configured to know where to forward NF management calls.
- Without SCP→NRF, ALL NF registrations fail with HTTP 500.

### `envsubst` / Template Processing
- `entrypoint.sh` runs `envsubst` to populate `configs/*.yaml` templates → `/open5gs/install/etc/open5gs/*.yaml`.
- Variables must be present in the container's environment (listed in `x-open5gs-common-env` in `docker-compose.yml` AND defined in `.env`).
- If `envsubst` is missing (no `gettext-base`), templates are silently skipped and all vars stay as literal `${VAR}` strings.

### ZMQ Radio (srsRAN)
- DU binds TX at `tcp://172.21.0.51:2000` (UE pulls DL samples from here).
- DU connects its RX to `tcp://172.21.0.34:2001` (UE binds here for UL).
- ZMQ sockets must be established before PHY-layer cell search begins.
- Cell search (`Attaching UE...`) can take 60-120 seconds after ZMQ link is up.
- Rapid container restarts cause `Address already in use` on ZMQ bind; add `restart_policy.delay` if needed.

### NF Registration Verification
Test NRF registration manually from inside any NF container:
```bash
docker exec 5g-core-amf curl -s --http2-prior-knowledge -X PUT \
  http://172.20.0.10:7777/nnrf-nfm/v1/nf-instances/<uuid> \
  -H "Content-Type: application/json" \
  -d '{"nfInstanceId":"<uuid>","nfType":"AMF","nfStatus":"REGISTERED",
       "plmnList":[{"mcc":"001","mnc":"01"}],
       "ipv4Addresses":["172.20.0.5"],
       "nfServices":[{"serviceInstanceId":"s1","serviceName":"namf-comm",
         "versions":[{"apiVersionInUri":"v1","apiFullVersion":"1.0.0"}],
         "scheme":"http","nfServiceStatus":"REGISTERED",
         "ipEndPoints":[{"ipv4Address":"172.20.0.5","transport":"TCP","port":7777}]}]}'
```
A 201/200 response with the profile body = NRF is healthy.

---

---

## Part 2: Near-RT RIC Bootstrap

This section captures the root causes and fixes required to get an srsRAN CU/DU split gNB registered in the O-RAN Near-RT RIC e2mgr (`/v1/nodeb/states` endpoint). The stack uses Docker Compose with `ric-plt-e2mgr`, `ric-plt-rtmgr:0.9.6`, and `ric-plt-e2:6.0.5` (e2term).

---

## 6. Issue 1: Wrong rtmgr Port in e2mgr Config

**Symptom**: e2mgr failed to notify rtmgr about new E2T instances. REST calls to rtmgr timed out or connection-refused.

**Root cause**: `configuration.yaml` had `routingManager.baseUrl: http://ric-rtmgr:8989/ric/v1/handles/`. The rtmgr config file declares `local: host: ":8989"`, but the swagger-generated HTTP server in `ric-plt-rtmgr:0.9.6` binds to **port 3800** regardless.

**Fix**: Changed port from 8989 to 3800.

```yaml
# ric/config/e2mgr/configuration.yaml
routingManager:
  baseUrl: http://ric-rtmgr:3800/ric/v1/handles/
```

**Lesson**: Don't trust the rtmgr YAML `local.host` value — verify the actual listening port inside the container (`ss -tlnp` or check swagger server code). The three rtmgr ports are:
- 4560 — RMR
- 8080 — xApp HTTP
- 3800 — NBI REST API (the one e2mgr needs)

---

## 7. Issue 2: Empty Message Type IDs in Routing Table

**Symptom**: Route table entries had empty message type fields: `mse||-1|ric-e2mgr:3801`. No RMR routing worked because message type IDs were blank.

**Root cause**: `rtmgr.Mtype` (a `map[string]string`) was empty. The rtmgr config file had no `messagetypes` section. The code reads a YAML array of strings like `"E2_TERM_INIT=1100"`, splits on `=`, and populates the map. Without this section, every `rtmgr.Mtype[messageType]` lookup returned `""`.

**Fix**: Added a `messagetypes` section to `rtmgr-config.yaml` with all required message type mappings:

```yaml
messagetypes:
  - "E2_TERM_INIT=1100"
  - "E2_TERM_KEEP_ALIVE_REQ=1101"
  - "E2_TERM_KEEP_ALIVE_RESP=1102"
  - "RIC_SCTP_CLEAR_ALL=1090"
  - "RIC_E2_SETUP_REQ=12001"
  - "RIC_E2_SETUP_RESP=12002"
  - "RIC_E2_SETUP_FAILURE=12003"
  # ... (37 entries total)
```

**Lesson**: The `Mtype` map is not populated from any built-in defaults or from `xapp-frame` — it must be explicitly provided in the config YAML. Verify with rtmgr debug logs: `Messgaetypes = {[E2_TERM_INIT=1100 ...]}`.

---

## 8. Issue 3: Missing PlatformRoutes for Static Routing

**Symptom**: When no E2T instance was registered yet, no routes existed at all. E2_TERM_INIT messages from e2term couldn't reach e2mgr.

**Root cause**: rtmgr generates two categories of routes:
1. **PlatformRoutes** — static, always present (from config YAML)
2. **Dynamic E2T routes** — only generated when `len(e2TermEp) > 0` (E2TERMINST endpoint exists)

Without PlatformRoutes, the routing table was empty until an E2T registered — but E2T couldn't register without routes.

**Fix**: Added 8 PlatformRoutes to `rtmgr-config.yaml`:

```yaml
PlatformRoutes:
  - messagetype: "E2_TERM_INIT"
    senderendpoint: ""
    subscriptionid: -1
    endpoint: "E2MAN"
    meid: ""
  - messagetype: "E2_TERM_KEEP_ALIVE_RESP"
    senderendpoint: ""
    subscriptionid: -1
    endpoint: "E2MAN"
    meid: ""
  # ... (8 routes total)
```

**Critical detail — field name casing**:
- Config YAML fields use **lowercase** JSON tags: `messagetype`, `senderendpoint`, `subscriptionid`, `endpoint`, `meid`
- These match the `PlatformRoutes` struct in `types.go`
- Do NOT use PascalCase (`MessageType`, `TargetEndPoint`) — those belong to a different swagger model struct and cause silent endpoint resolution failures

**Lesson**: The `endpoint` field in PlatformRoutes only supports: `SUBMAN`, `E2MAN`, `A1MEDIATOR`. There is no `E2TERM` or `E2TERMINST` option — e2term routes can only be generated dynamically.

---

## 9. Issue 4: Keep-Alive Death Spiral (The Final Blocker)

**Symptom**: E2T instance registered successfully but was deleted within ~30 seconds. The cycle repeated indefinitely: register → delete → register → delete.

**Root cause — a timing race between route push and E2T registration**:

```
Timeline:
T+0s   e2mgr starts
T+20s  rtmgr starts, queries e2mgr /v1/e2t/list → [] (empty)
T+25s  e2term starts, sends E2_TERM_INIT → e2mgr receives it
T+26s  e2mgr calls rtmgr POST /ric/v1/handles/e2t → E2T created
T+30s  rtmgr reconciliation: no E2TERMINST yet (hasn't re-queried e2mgr)
       Pushes 8-entry route table (PlatformRoutes only)
       *** This OVERWRITES e2mgr's seed routes including rte|1101|ric-e2term:38000 ***
       e2mgr can no longer send keep-alive REQ to e2term

T+40s  rtmgr reconciliation: sees E2T now, creates E2TERMINST endpoint
T+55s  rtmgr pushes 22-entry route table with dynamic routes (keep-alive REQ restored)
       *** But e2mgr already deleted E2T at T+56s ***

T+56s  e2mgr keep-alive timeout expires (10s delay + 4.5s response + 15s deletion = 29.5s)
       E2T deleted. rtmgr sees empty E2T list, removes E2TERMINST. Back to square one.
```

The fundamental problem: the `E2_TERM_KEEP_ALIVE_REQ` route (1101, from e2mgr to e2term) is a **dynamic route** that only exists when E2TERMINST is present. But rtmgr's first route push (without E2TERMINST) overwrites e2mgr's seed routing table, creating a ~30-second window with no keep-alive route. The default e2mgr timeout budget (29.5s) is shorter than this window.

**Fix**: Increased the three keep-alive timers in `configuration.yaml`:

```yaml
# Before (total budget: ~29.5s — too short)
keepAliveResponseTimeoutMs: 4500
keepAliveDelayMs: 10000
e2tInstanceDeletionTimeoutMs: 15000

# After (total budget: ~210s — survives the route gap)
keepAliveResponseTimeoutMs: 60000
keepAliveDelayMs: 30000
e2tInstanceDeletionTimeoutMs: 120000
```

**Why this works**: The E2T survives long enough for rtmgr to:
1. Query e2mgr and discover the new E2T instance
2. Create the E2TERMINST endpoint
3. Generate and push the 22-entry route table with dynamic routes
4. e2mgr receives the keep-alive REQ route and keep-alive succeeds

**Lesson**: The default keep-alive timers assume routes are pre-provisioned (as in a Kubernetes deployment with a service mesh). In a Docker Compose environment with file-based SDL and no pre-existing E2T state, the bootstrap window is much longer.

---

## 10. Required Restart Order ("RIC Reboot Dance")

Order matters because e2term only sends `E2_TERM_INIT` once on boot:

```
1. Flush Redis:       docker exec ric-dbaas redis-cli FLUSHALL
2. Restart e2mgr:     docker restart ric-e2mgr     (picks up config changes)
3. Wait 5s
4. Restart rtmgr:     docker restart ric-rtmgr      (starts reconciliation loop)
5. Wait 10s
6. Restart e2term:    docker restart ric-e2term      (sends E2_TERM_INIT ONCE)
```

If e2term starts before rtmgr has established RMR connectivity, the `E2_TERM_INIT` message fails with `RMR_ERR_NOENDPT` and is never retried. The compose file already has `command: sh -c "sleep 5 && ./startup.sh"` on e2term for this reason.

---

## 11. RIC Port Map

| Container   | RMR Port | REST/HTTP Port | SCTP Port |
|-------------|----------|----------------|-----------|
| e2term      | 38000    | —              | 36421     |
| e2mgr       | 3801     | 3800           | —         |
| rtmgr       | 4560     | 3800           | —         |
| submgr      | 4560     | —              | —         |
| a1mediator  | 4562     | —              | —         |

---

## 12. RIC Verification Commands

```bash
# Check E2T instance persistence
docker exec ric-e2mgr curl -s http://localhost:3800/v1/e2t/list

# Check gNB registration
docker exec ric-e2mgr curl -s http://localhost:3800/v1/nodeb/states

# Check full nodeb detail
docker exec ric-e2mgr curl -s http://localhost:3800/v1/nodeb/gnbd_001_001_00019b_0

# Check rtmgr route table size (should be 22 entries when E2T is active)
docker logs ric-rtmgr --tail 20 2>&1 | grep "Route Update Status"

# Check e2term RMR connectivity
docker logs ric-e2term --tail 10 2>&1 | grep "RMR \[INFO\] sends"
```

---

## 13. Files Modified

| File | Change |
|---|---|
| `docker-compose.yml` | Added 9 NF IP/port vars to `x-open5gs-common-env` |
| `Dockerfile.5gscore` | Added `gettext-base`; rebuilt image |
| `Dockerfile.srsue` | Added `libpcsclite1`; fixed shared lib copy with bind-mount find |
| `configs/amf.yaml` | Added `amf_name`, `network_name`, `time.t3512` |
| `configs/smf.yaml` | `gtp` → `gtpc` + `gtpu`; PFCP UPF `uri` → `address/port` |
| `configs/nssf.yaml` | `nssai_supported` → `sbi.client.nsi` |
| `configs/sepp1.yaml` | Removed undefined peer URIs; added NRF/SCP clients; fixed `n32` section |
| `configs/scp.yaml` | Added `sbi.client.nrf` |
| `configs/*.yaml` (all) | Fixed `logger.file` → `logger.file.path` format |
| `srsran/configs/du.yml` | Set `e2.enable_du_e2: false` |
| `srsran/configs/ue.conf` | Removed unrecognised `gw.tun_dev_name` option |
| `ric/config/e2mgr/configuration.yaml` | Fixed rtmgr port (8989→3800), increased keep-alive timers, set debug logging |
| `ric/config/rtmgr/rtmgr-config.yaml` | Added `messagetypes` (37 entries), added `PlatformRoutes` (8 static routes), set debug logging |
