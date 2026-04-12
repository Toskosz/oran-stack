# O-RAN Stack Learnings

Accumulated debugging notes for the srsRAN + Open5GS + Near-RT RIC Docker stack.

---

## Part 1: 5G Core & srsRAN

---

## 1. Root Cause Chain (fully resolved)

### 1.1 `gettext-base` missing from Docker image

**Symptom:** `envsubst` not found; NF config templates were never processed at container start,
leaving all `${VAR}` placeholders as empty strings.

**Cause:** `dockerfiles/Dockerfile.5gscore` listed `gettext-base` but the image in use pre-dated that line
(built March 19 before the change, or the layer was cached before the fix).

**Fix:** Rebuild `teste-core:latest` image.
```
docker build -f dockerfiles/Dockerfile.5gscore -t teste-core:latest .
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

**Fix:** Add `libpcsclite1` to the runtime apt-get install block in `dockerfiles/Dockerfile.srsue`.

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

## Part 3: Ansible Image Build Pipeline

---

## 14. `dockerhub_password` undefined despite vault file existing

**Symptom:**
```
[ERROR]: Task failed: Finalization of task args for 'community.docker.docker_login' failed:
Error while resolving value for 'password': 'dockerhub_password' is undefined
```

**Cause:** `group_vars/all.vault.yml` is not a filename Ansible auto-loads. Ansible's
`host_group_vars` vars plugin resolves `group_vars/` relative to the **inventory file** and
the **playbook file** — never relative to `ansible.cfg`. The directory `ansible/group_vars/`
is adjacent to neither, so it was silently ignored and `vault_dockerhub_password` was never
defined.

**Fix:** Convert the flat files into a directory structure next to the inventory file:
```
ansible/inventories/
  localhost.ini
  group_vars/        ← adjacent to inventory: loaded automatically
    all/
      vars.yml       ← was ansible/group_vars/all.yml
      vault.yml      ← was ansible/group_vars/all.vault.yml
```
Ansible auto-loads every file inside a `group_vars/all/` directory, including the vault file
(decrypted via `--ask-vault-pass` or `vault_password_file`).

**Lesson:** `group_vars/` must sit next to the inventory file or the playbook file.
A file named `all.vault.yml` at any other location is silently ignored. Use the `all/`
directory pattern so both plain vars and vault vars are loaded from the same place.

---

## 15. Docker daemon not running

**Symptom:**
```
[ERROR]: Module failed: Error connecting: Error while fetching server API version:
('Connection aborted.', FileNotFoundError(2, 'No such file or directory'))
```

**Fix:**
```bash
sudo systemctl start docker
# If not installed:
sudo apt-get install -y docker.io
sudo systemctl enable --now docker
sudo usermod -aG docker $USER && newgrp docker
```

---

## 16. Build succeeds but push fails with "Cannot find image locally"

**Symptom:**
```
[ERROR]: Module failed: Cannot find the image x0tok/oran-5gcore:latest locally.
```
Even though images existed on the host (visible in `docker images`).

**Cause:** The Dockerfile paths and build contexts in `group_vars` were stale and didn't
match the actual repository layout. All four Dockerfiles live in `dockerfiles/` with
`.5gscore`/`.webui`/`.srsran`/`.srsue` suffixes; the vars file still referenced
`Dockerfile`, `Dockerfile.webui`, `srsran/Dockerfile`, etc. The build tasks failed
silently (or were skipped due to idempotency), so no image was ever produced under
the expected name.

**Fix:** Correct `dockerfiles` and `build_contexts` in `vars.yml`:
```yaml
dockerfiles:
  core:   "dockerfiles/Dockerfile.5gscore"
  webui:  "dockerfiles/Dockerfile.webui"
  srsran: "dockerfiles/Dockerfile.srsran"
  srsue:  "dockerfiles/Dockerfile.srsue"

build_contexts:
  core:   "."
  webui:  "."
  srsran: "."
  srsue:  "."
```
All four build contexts are the repo root because `Dockerfile.5gscore` copies `configs/`
and `entrypoint.sh` from there, and the srsRAN Dockerfiles are multi-stage (no local
`COPY` from context needed).

---

## 17. `RUN --mount` fails without BuildKit (`Dockerfile.srsue`)

**Symptom:**
```
fatal: the --mount option requires BuildKit.
Refer to https://docs.docker.com/go/buildkit/ to learn how to build images with BuildKit enabled
```
Only `Dockerfile.srsue` was affected — the other three Dockerfiles use only plain
`COPY --from=builder` and have no BuildKit dependency.

**Root cause:** `Dockerfile.srsue` used `RUN --mount=type=bind,from=builder,...` to find
and copy `.so` files scattered across the srsRAN 4G build tree. The
`community.docker.docker_image` Ansible module calls the Docker API directly (via the
Python SDK) and does not honour the `DOCKER_BUILDKIT=1` environment variable — that
variable only affects the Docker CLI, not API clients.

**Why only srsue?** srsRAN 4G scatters shared libraries across many unpredictable
subdirectories in its build tree. A `find *.so*` glob was needed rather than explicit
`COPY` paths, and `--mount=type=bind` was chosen to avoid adding a large intermediate
layer. The other three Dockerfiles copy only specific known binary paths.

**Fix:** Replace the `--mount` with an equivalent classic approach that works without
BuildKit:
```dockerfile
# Before (BuildKit only)
RUN --mount=type=bind,from=builder,source=/opt/srsRAN_4G/build,target=/srsran-build \
    find /srsran-build -name "*.so*" -exec cp -P {} /usr/local/lib/ \; && ldconfig

# After (no BuildKit required; same final image size)
COPY --from=builder /opt/srsRAN_4G/build /srsran-build
RUN find /srsran-build -name "*.so*" -exec cp -P {} /usr/local/lib/ \; \
    && ldconfig \
    && rm -rf /srsran-build
```
The `rm -rf /srsran-build` at the end keeps the layer size equivalent to the `--mount`
version (which never wrote the build tree into a layer at all).

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
| `dockerfiles/Dockerfile.5gscore` | Added `gettext-base`; rebuilt image |
| `dockerfiles/Dockerfile.srsue` | Added `libpcsclite1`; fixed shared lib copy with bind-mount find |
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

---

## Part 5: GKE Helm Deployment — RAN (srsRAN CU/DU/UE)

---

## 20. F1AP SCTP: kube-proxy conntrack kills association after F1SetupResponse

**Symptom:** After the CU sends `F1SetupResponse`, the CU's F1AP SCTP association
immediately enters `SHUTDOWN_ACK_SENT` while the DU stays `ESTABLISHED`. No error is
logged by either side. This happened 100% of the time and made F1 setup impossible.

**Root cause:** The DU connected to the `srs-cu` **ClusterIP** service. kube-proxy
performed DNAT (rewrote the destination IP in the IP header), but Linux conntrack for SCTP
is unreliable in cloud environments: after `F1SetupResponse`, conntrack failed to track
the SCTP association state and synthesised a spurious `SHUTDOWN` chunk. The CU received
the spurious SHUTDOWN, entered `SHUTDOWN_ACK_SENT`, and closed silently. The DU never
saw it at the application layer.

In the local Docker Compose setup the DU connected directly to the CU IP — no NAT, no
conntrack, no issue.

**Fix:** Convert the `srs-cu` Service to **Headless** (`clusterIP: None`).
With a headless service, Kubernetes creates DNS A-records pointing directly to the backing
pod IP — no virtual IP, no kube-proxy DNAT, no conntrack involved. The DU resolves
`srs-cu` and gets the actual CU pod IP, routing directly as in Docker Compose.

```yaml
# helm/ran/templates/deployments.yaml
apiVersion: v1
kind: Service
metadata:
  name: srs-cu
spec:
  clusterIP: None   # ← headless: DNS → pod IP directly, no kube-proxy
  selector:
    app: srs-cu
  ports:
    - name: f1ap
      port: 38472
      protocol: SCTP
```

**Important:** Kubernetes does not allow changing `clusterIP` in-place. Must
`kubectl delete service srs-cu -n ran` first, then `helm upgrade`.

**Lesson:** SCTP over kube-proxy ClusterIP is unreliable on GKE (standard nodes, no
Cilium/Dataplane V2). The conntrack SCTP state machine misbehaves under load. Use headless
services for any SCTP control-plane interface (F1AP, NGAP, E2AP) where the server side is
a single pod. Only E2AP to e2term (which is a multi-client server) proved stable through
ClusterIP — possibly because e2term's SCTP association patterns differ.

---

## 21. CU and DU bind addresses must be the pod IP, not `0.0.0.0`

**Symptom:** With `bind_addr: 0.0.0.0` in `cu.yml` and `du.yml`, the CU closed the SCTP
association immediately after `F1SetupResponse`. The TNL address IEs in F1SetupRequest and
F1SetupResponse contained `0.0.0.0`, which srsRAN cannot resolve to a valid peer address
for F1-U (GTP-U user-plane). This caused a secondary teardown separate from the conntrack
issue.

**Fix:** Use the actual pod IP in all bind addresses. Since pod IPs are assigned at runtime,
use config templates with `${POD_IP}` substituted via an `initContainer` using `envsubst`
and the Kubernetes Downward API:

```yaml
# helm/ran/templates/deployments.yaml — CU and DU initContainers
- name: render-config
  image: alpine:3.19
  command:
    - sh
    - -c
    - |
      apk add --no-cache gettext > /dev/null 2>&1
      envsubst < /mnt/srsran/templates/cu.yml.tpl > /mnt/srsran/configs/cu.yml
  env:
    - name: POD_IP
      valueFrom:
        fieldRef:
          fieldPath: status.podIP
```

```yaml
# helm/ran/templates/configmap-srsran-configs.yaml — cu.yml.tpl excerpt
cu_cp:
  amf:
    bind_addr: ${POD_IP}
  f1ap:
    bind_addr: ${POD_IP}
cu_up:
  f1u:
    socket:
      - bind_addr: ${POD_IP}
  ngu:
    socket:
      - bind_addr: ${POD_IP}
```

---

## 22. DU log to file blocks startup; use `/dev/stdout`

**Symptom:** With `log.filename: /mnt/srsran/logs/du.log`, the DU log file was frozen at
exactly 4096 bytes (one filesystem block). The DU process was alive (7% CPU from ZMQ),
F1 Setup had completed, but: no E2 connection was attempted, no cell activation message
appeared, and the UE stayed at `Attaching UE...` indefinitely.

**Root cause:** The DU writes a large SIB1 ASN.1 JSON dump (≈6 KB) to the log file
synchronously during the F1 Setup completion handler. The hostPath volume backing
`/mnt/srsran/logs/` limited the write to one block (4096 bytes) before stalling. Because
the startup sequence is linear (log SIB1 → start E2 → activate cell), blocking on the log
write prevented all subsequent steps.

The 7% CPU was the ZMQ thread pool, which is started earlier in the sequence and continues
running regardless.

**Fix:** Set `log.filename: /dev/stdout`. Stdout is a pipe drained continuously by the
container runtime — it never blocks.

```yaml
# du.yml.tpl
log:
  filename: /dev/stdout
  all_level: info
```

**Note:** The CU was already logging to `/dev/stdout` and had no issue. The DU originally
used a file to avoid mixing DU logs with the ZMQ noise on stdout. The ZMQ `[zmq:tx:0:0]
Waiting for request` / `[zmq:rx:0:0] Waiting for data` lines print at 1 Hz while idle —
use `grep -v "Waiting for"` when reading DU logs.

---

## 23. F1SetupFailure: `message-not-compatible-with-receiver-state` on DU restart (**RESOLVED — P4**)

**Symptom:** After the DU pod restarts (new pod, new IP), the new DU sends `F1SetupRequest`
and immediately receives `F1SetupFailure` with cause
`message-not-compatible-with-receiver-state`. The DU has `max_retries: 1` (hardcoded, not
configurable) and gives up, so the cell never activates.

**Root cause:** The CU retains DU state in memory. When the previous DU pod terminates, its
SCTP association to the CU drops. The CU marks DU 0 as disconnected but does not remove it
from its internal state immediately. When the new DU connects and sends `F1SetupRequest`,
the CU sees a duplicate DU ID while the old DU entry is still present, and rejects it. The
CU purges the stale entry ~23 s after SCTP COMM_LOST.

**Fix (implemented):** The DU Deployment's `wait-for-cu` initContainer
(`helm/ran/templates/deployments.yaml`) was extended with a post-ready hold-off step.
After confirming the CU process is reachable (DNS + UDP F1-U port probe), the container
sleeps for `duF1SetupHoldOffSec` seconds (default: **30 s**, set in
`helm/ran/values.yaml`) before allowing srsRAN to start. This guarantees the 23 s CU
cleanup window has elapsed before the DU's single F1Setup attempt is made, eliminating
the race entirely without requiring a CU restart.

**Previous workaround (no longer needed for normal restarts):**

```bash
kubectl rollout restart deployment/srs-cu -n ran
# wait for CU ready, then restart DU
kubectl rollout restart deployment/srs-du -n ran
```

**Restart order that works (still valid for hard CU crashes):**
1. Restart CU → wait `rollout status`
2. Restart DU → F1 Setup succeeds on first attempt against fresh CU state
3. Restart UE → ZMQ connects to active cell

---

## 24. E2AP SCTP through ClusterIP — works, unlike F1AP

**Observation:** After the F1/bind-addr fixes, the DU connects to `e2term` via its
ClusterIP (`10.8.5.199:36421`) and the SCTP association stays `ESTABLISHED`. No conntrack
teardown occurs.

**Why it works here:** e2term is a persistent server that handles many short-lived SCTP
associations. Its SCTP socket patterns (rapid INIT/COOKIE/ESTABLISHED cycles from many
nodes) may keep conntrack in a more valid state. Alternatively, the E2 setup packet exchange
is short enough to complete before conntrack times out.

**Implication:** E2AP does not need a headless service on this GKE setup. Only the F1AP
interface (where the DU connects to the CU's SCTP server and holds a long-lived association
with infrequent keepalives) triggers the conntrack bug.

---

## 25. ZMQ radio bootstrap deadlock: UE must start after cell is active

**Symptom:** Both DU and UE are running, ZMQ TCP connections are `ESTAB`, but:
- DU logs `[zmq:tx:0:0] Waiting for data` (MAC scheduler has no DL frames to send)
- UE logs `[zmq:rx:0:0] Waiting for data` (PHY has no DL samples to decode)
- UE stays at `Attaching UE...` indefinitely

**Root cause:** srsRAN ZMQ uses a pull model: the UE PHY sends a REQ for each DL subframe;
the DU MAC responds with a subframe's worth of IQ samples. The DU MAC only produces frames
when it receives a REQ tick. The UE only sends REQ ticks after it receives at least one
frame to synchronise its timing. Neither side will go first unless the UE connects to an
already-ticking DU.

In Docker Compose both containers start nearly simultaneously and the ZMQ handshake
bootstraps within a few ms. On Kubernetes, if the UE starts while the DU cell is not yet
active (e.g. because F1 Setup is still in progress), the ZMQ session gets into a deadlock
state that persists even after F1 Setup completes.

**Fix:** Add a post-probe delay in the UE's `wait-for-du` init container so the UE waits
for the cell to be active, not just the ZMQ port to be open:

```yaml
# helm/ran/templates/deployments.yaml — srsue initContainers
- name: wait-for-du
  image: busybox:1.36
  command:
    - sh
    - -c
    - |
      until nc -z srs-du 2000; do
        echo "waiting for DU ZMQ port..."
        sleep 3
      done
      echo "DU ZMQ port open — waiting 10s for cell to activate..."
      sleep 10
```

The 10-second sleep covers the time from the DU's ZMQ port opening (early in DU startup)
to `SCHED: Cell scheduling was activated` (after F1 Setup completes, typically 2–4 seconds
after the ZMQ port opens).

---

## 26. Open5GS subscriber provisioning: MongoDB replica set not initialised

**Symptom:** The UE could not attach. The `mongodb-init-scripts` ConfigMap contained the
correct subscriber document, but the subscriber collection was empty.

**Root cause:** MongoDB was deployed as a replica set member (`isreplicaset: true`) but
`rs.initiate()` had never been called, leaving it in a state of `Does not have a valid
replica set config` — neither primary nor secondary. All writes to the database (including
the init scripts) failed with `node is not in primary or recovering state`.

**Fix:** Run `rs.initiate()` once after MongoDB starts:

```bash
kubectl exec -n 5g-core mongodb-0 -- mongosh \
  "mongodb://localhost:27017/open5gs?directConnection=true" \
  --quiet --eval 'rs.initiate()'
```

Then provision the subscriber directly:

```bash
kubectl exec -n 5g-core mongodb-0 -- mongosh \
  "mongodb://localhost:27017/open5gs?directConnection=true" \
  --quiet --eval '
db.subscribers.insertOne({
  imsi: "001010000000001",
  security: {
    k: "465B5CE8B199B49FAA5F0A2EE238A6BC",
    op: null,
    opc: "E8ED289DEBA952E4283B54E88E6183CA",
    amf: "8000",
    sqn: NumberLong("0")
  },
  ambr: { downlink: {value:1,unit:3}, uplink: {value:1,unit:3} },
  slice: [{
    sst: 1,
    default_indicator: true,
    session: [{
      name: "internet", type: 3, pcc_rule: [],
      ambr: { downlink: {value:1,unit:3}, uplink: {value:1,unit:3} },
      qos: { index: 9, arp: {priority_level:8,
        pre_emption_capability:1, pre_emption_vulnerability:1} }
    }]
  }],
  access_restriction_data: 32,
  subscriber_status: 0,
  operator_determined_barring: 0,
  network_access_mode: 0
})'
```

**Long-term fix needed:** Add a Kubernetes Job to the 5g-core Helm chart that runs after
MongoDB is ready and calls `rs.initiate()` + seeds the subscriber. The existing
`mongodb-init-scripts` ConfigMap is correct but is never executed because there is no Job
or initContainer wiring it up.

---

## 27. Current state (end of Part 5 session)

| Component | Status | Notes |
|---|---|---|
| 5g-core | All 16 pods Running | Subscriber provisioned manually |
| near-rt-ric | All 7 pods Running | |
| srs-cu | Running, `10.4.0.33` | NG Setup with AMF ✅, F1 Setup ✅ |
| srs-du | Running, `10.4.0.34` | F1 Setup ✅, E2 connected ✅, cell active ✅ |
| srsue | Running, `10.4.1.31` | ZMQ connected, `Attaching UE...` |
| F1AP SCTP | ESTAB both sides | DU→CU pod IP direct (headless svc) ✅ |
| E2AP SCTP | ESTAB | DU→e2term ClusterIP (no conntrack issue) ✅ |
| UE attach | **Not yet confirmed** | UE scanning, cell active, subscriber provisioned |

**Immediate next steps:**
1. Confirm UE finds cell and sends PRACH (watch DU for `Random Access` or `UE connected` log)
2. If UE attaches: check AMF logs for `Registration Accept` and UPF for GTP-U tunnel
3. Verify E2 gNB registration: `kubectl exec -n near-rt-ric ric-e2mgr -- curl -s http://localhost:3800/v1/nodeb/states`
4. Fix MongoDB replica set init in the 5g-core Helm chart (Job + rs.initiate)

---

## 28. Files Modified (Part 5)

| File | Change |
|---|---|
| `helm/ran/templates/deployments.yaml` | `srs-cu` Service: `clusterIP: None` (headless); CU/DU: added `render-config` initContainer (envsubst + Downward API); UE `wait-for-du`: added 10s post-probe sleep |
| `helm/ran/templates/configmap-srsran-configs.yaml` | `cu.yml` → `cu.yml.tpl` with `${POD_IP}`; `du.yml` → `du.yml.tpl` with `${POD_IP}`; DU log: file → `/dev/stdout` |

---

## Part 4: GKE Helm Deployment — 5g-core

---

## 18. `helm --wait` times out with `context deadline exceeded`

**Symptom:**
```
TASK [deploy_5g_core : Deploy 5g-core Helm chart]
fatal: [localhost]: FAILED! => {"msg": "Failure when executing Helm command. Exited 1.\n
stdout: Release \"5g-core\" does not exist. Installing it now.\n
stderr: Error: context deadline exceeded\n"}
```

Two independent root causes caused the 600 s Helm wait deadline to expire.

---

### 18.1 `wait-for-mongodb` init containers had no retry loop

**Files:** `helm/5g-core/templates/deployment-nrf.yaml`, `deployment-webui.yaml`

**Cause:** Both `nrf` and `webui` pods ran a single-shot `mongosh ping` as their init
container — no loop, no retry:
```yaml
command: ["mongosh", "--host", "mongodb:27017", "--eval", "db.adminCommand('ping')", "--quiet"]
```
If MongoDB's readiness probe had not yet passed at that exact moment, the init container
exited non-zero. Kubernetes then put the pod into `Init:CrashLoopBackOff` with exponential
backoff (10 s, 20 s, 40 s…). The 600 s Helm `--wait` deadline expired before the pods ever
became `Ready`.

**Fix:** Wrap the command in a shell retry loop:
```yaml
command:
  - sh
  - -c
  - |
    until mongosh --host mongodb:27017 --eval "db.adminCommand('ping')" --quiet; do
      echo "Waiting for MongoDB..."; sleep 5;
    done
```

**Lesson:** Any init container that depends on another service becoming ready must loop.
A single-shot probe will race against pod startup order and cause `CrashLoopBackOff`
cascades that consume the entire Helm wait budget.

---

### 18.2 GCP external load balancers do not support SCTP

**File:** `helm/5g-core/templates/deployment-amf.yaml`

**Cause:** `amf-ngap` was a `type: LoadBalancer` service with `protocol: SCTP` on port 38412.
GCP's external Network Load Balancers (both classic and passthrough) only support **TCP and
UDP** as forwarding rule protocols. SCTP is rejected at the GCP API level:

```
Error syncing load balancer: failed to ensure load balancer: failed to create forwarding rule
for load balancer (…): invalid protocol SCTP, only TCP and UDP are supported
```

The service stayed permanently at `EXTERNAL-IP: <pending>`, and Helm's `--wait` flag treats
an unready `LoadBalancer` service as a deployment failure.

**What does not work:**
- `cloud.google.com/load-balancer-type: "External"` — this is the annotation for *internal*
  passthrough NLBs and has no effect on external ones.
- `networking.gke.io/load-balancer-type: "External"` — routes to the NEG-based external LB,
  which also rejects SCTP at the GCP forwarding rule level.

**GKE Dataplane V2 (Cilium) caveat:** The GKE docs for SCTP describe **Pod-to-Pod** and
**ClusterIP** SCTP via Cilium — not external LoadBalancer exposure. External SCTP LB is
unsupported regardless of dataplane choice.

**Fix:** Change `amf-ngap` to `type: NodePort`. Kubernetes/kube-proxy handles SCTP via
iptables rules at the node level, which works without GCP LB involvement:
```yaml
spec:
  type: NodePort
  externalTrafficPolicy: Local
  ports:
    - name: ngap
      port: 38412
      targetPort: 38412
      protocol: SCTP
      # nodePort omitted — auto-assigned from 30000-32767 range
```

**Note:** Static `nodePort: 38412` is invalid — GKE's NodePort range is 30000–32767.
Let Kubernetes assign the port dynamically and read it back after deployment.

**CU configuration change required:** Update the srsRAN CU's AMF N2 address from the old
LoadBalancer IP to any GKE node's external IP on the dynamically assigned NodePort.

**Lesson:** GCP cannot load-balance raw SCTP externally. For 5G N2 (NGAP/SCTP) exposure on
GKE, use `NodePort` and connect directly to a node IP. If a stable single endpoint is needed,
use a GCP forwarding rule created manually (outside Kubernetes) pointing at the NodePort.

---

### 18.3 Ansible task polling for LoadBalancer IP now polls NodePort

**File:** `ansible/roles/deploy_5g_core/tasks/main.yml`

The old task used `retries: 20 / delay: 15` waiting for
`status.loadBalancer.ingress[0].ip` to appear — it would always fail (and block for 5
minutes) since the service is now a NodePort.

**Fix:** Replace the LB polling task with two tasks that read the node external IP and the
assigned NodePort:
```yaml
- name: Get AMF NGAP NodePort Service
  kubernetes.core.k8s_info:
    kind: Service
    name: amf-ngap
    namespace: "{{ namespaces.core }}"
  register: amf_svc

- name: Get GKE node external IPs
  kubernetes.core.k8s_info:
    kind: Node
  register: cluster_nodes

- name: Show AMF NGAP NodePort endpoint
  ansible.builtin.debug:
    msg: >-
      AMF NGAP SCTP endpoint (NodePort):
      {{ cluster_nodes.resources[0].status.addresses
         | selectattr('type', 'equalto', 'ExternalIP')
         | map(attribute='address') | first }}:{{
      amf_svc.resources[0].spec.ports
         | selectattr('name', 'equalto', 'ngap')
         | map(attribute='nodePort') | first }}
```

---

## 19. Files Modified (Part 4)

| File | Change |
|---|---|
| `helm/5g-core/templates/deployment-nrf.yaml` | `wait-for-mongodb` init container: single-shot → retry loop |
| `helm/5g-core/templates/deployment-webui.yaml` | `wait-for-mongodb` init container: single-shot → retry loop |
| `helm/5g-core/templates/deployment-amf.yaml` | `amf-ngap`: `LoadBalancer` → `NodePort`; removed GCP LB annotations |
| `ansible/roles/deploy_5g_core/tasks/main.yml` | Replaced LB IP polling with NodePort + node IP read |
| `ansible/roles/deploy_5g_core/tasks/main.yml` | Replaced LB IP polling with NodePort + node IP read |

---

## Part 6: GKE Helm Deployment — N2 SCTP Flapping, UE Log Fix

---

## 29. N2/NGAP SCTP flapping — CU→AMF connection unstable

**Symptom:** After deploying on fresh nodes, `srs-cu` showed 5+ restarts and a rapid
connect/disconnect loop on N2. AMF logged `"connection refused!!!"` every ~1.2 seconds
immediately after `NGSetupResponse`. The CU had just received a valid `NGSetupResponse`
but the SCTP association was torn down within ~300ms.

**Cause:** Identical root cause to issue §16 (F1AP SCTP conntrack bug), but on the N2 path.
The CU was connecting to `amf-ngap.5g-core.svc.cluster.local` which resolved to the
NodePort `ClusterIP: 10.8.7.111`. When CU and AMF pods were on **different nodes**,
kube-proxy DNAT rewrote the destination address for each packet, confusing the SCTP
multi-stream conntrack. The SCTP association was torn down after NGSetupResponse was
delivered but before any further N2 messages could flow.

When both pods happened to land on the same node (after a CU restart), the connection was
stable because local traffic doesn't cross kube-proxy DNAT. This made the bug intermittent
and node-scheduling-dependent.

**Fix:** Add a headless service `amf-ngap-headless` (`clusterIP: None`) to
`helm/5g-core/templates/deployment-amf.yaml`. Update `amfAddress` in
`helm/ran/values.yaml` from `amf-ngap.5g-core.svc.cluster.local` to
`amf-ngap-headless.5g-core.svc.cluster.local`. With `clusterIP: None`, DNS resolves
directly to the AMF pod IP, bypassing kube-proxy DNAT entirely.

The existing `amf-ngap` NodePort service is retained for external gNBs.

**Lesson:** Any SCTP service used for intra-cluster communication should be headless.
This applies to: AMF N2/NGAP (N2), srs-cu F1AP (already fixed §16), and e2term E2AP.
The e2term service is a regular ClusterIP — if SCTP issues appear on E2, apply the same fix.

**Helm upgrade commands used:**
```bash
# Add headless service to 5g-core
helm upgrade 5g-core helm/5g-core/ -n 5g-core --reuse-values --timeout 120s

# Update amfAddress (must use --set, not -f values.yaml, to avoid losing stored image values)
helm upgrade ran helm/ran/ -n ran --reuse-values \
  --set amfAddress="amf-ngap-headless.5g-core.svc.cluster.local" --timeout 120s

# Restart CU to re-render config with new address
kubectl rollout restart deployment/srs-cu -n ran

# Restart DU (stale F1AP state after CU restart — same as §26)
kubectl rollout restart deployment/srs-du -n ran
```

---

## 30. Helm `--reuse-values` vs `-f values.yaml` — stored values overwrite pitfall

**Symptom:** Running `helm upgrade ran helm/ran/ -n ran -f helm/ran/values.yaml` caused
`InvalidImageName` errors on all three ran pods because the image repository became `":latest"`.

**Cause:** The `ran` Helm release had user-supplied values `images.srsran.repository=x0tok/oran-srsran`
and `images.srsue.repository=x0tok/oran-srsue` stored in the Helm release (set during the
initial Ansible deploy via `--set`). The file `helm/ran/values.yaml` still has
`repository: ""` as placeholders. Running `-f values.yaml` merged the file on top of the
stored values, overwriting the image repositories with empty strings.

**Fix:** Always use `--reuse-values` when upgrading to keep stored values, then apply
targeted overrides with `--set`:
```bash
helm upgrade ran helm/ran/ -n ran --reuse-values \
  --set amfAddress="amf-ngap-headless.5g-core.svc.cluster.local"
```

If a full values file override is needed, use `helm get values ran -n ran -o yaml > /tmp/ran-values.yaml`,
edit the file, and then `helm upgrade ran helm/ran/ -n ran -f /tmp/ran-values.yaml`.

---

## 31. Helm rollback removes the release entirely when a failed revision exists

**Symptom:** `helm rollback ran -n ran` succeeded, but then `helm list -n ran` showed no
release. Subsequent `helm upgrade` returned `Error: "ran" has no deployed releases`.

**Cause:** The `ran` release history at rollback time had: revision 10 (`failed`/`superseded`),
revision 11 (`failed` due to InvalidImageName). Helm's rollback went to revision 9 but that
revision was already `superseded`. Helm cleaned up the history and ended with no `deployed`
revision, leaving the release in a broken state.

**Fix:** After a rollback that leaves no deployed release, use `helm install` (not `helm upgrade`).
Check for any existing resources in the namespace first (`kubectl get all -n ran`) and delete
them if they have stale owner references, or use `--replace` flag if supported.

---

## 32. UE log file `/mnt/srsran/logs/ue.log` produces 0 bytes — UE attach progress invisible

**Symptom:** srsUE was stuck at `Attaching UE...` with no further console output and no
PHY-level logging visible. The file `/mnt/srsran/logs/ue.log` existed but was 0 bytes.

**Cause:** srsUE (srsRAN_4G) writes all detailed logs to `[log] filename` in `ue.conf`.
The file is created at startup but PHY scanning logs are only written when events occur.
Since the PHY had not yet detected the cell, nothing had been logged yet. Without stdout
logging, the container log showed only the static startup banner and `Attaching UE...`.

**Fix:** Change `filename = /mnt/srsran/logs/ue.log` to `filename = /dev/stdout` in the
UE config template (`helm/ran/templates/configmap-srsran-configs.yaml`), the same fix
applied to the DU (`du.yml`) in §26.

---

## 33. `[gw] netns = ue1` — network namespace not present in container

**Observation:** The `ue.conf` had `[gw] netns = ue1`. No `ue1` network namespace exists
in the container. srsUE would fail to set up the data plane TUN interface after attach.

**Fix:** Remove `netns = ue1` from the `[gw]` section in the UE config template. With
`netns` unset, srsUE creates the TUN interface in the default network namespace (the pod's
network namespace), which is correct for Kubernetes.

---

## 34. GKE preemptible nodes — full cluster loss during active session

**Symptom:** All GKE nodes were preempted simultaneously during the session. Kubernetes
went from 2 Running nodes → 0 nodes → cluster entered `RECONCILING` state → briefly showed
2 new nodes → then cluster entered `STOPPING` state → billing error (403).

**Root cause:** GCP preemptible VMs have a 24-hour maximum lifetime and can be reclaimed
at any time. When both nodes were preempted simultaneously, the cluster had no nodes.
GKE attempted to recreate the node pool but GCP returned a billing error
(`This API method requires billing to be enabled`), indicating the project's billing account
was detached or exhausted.

**Impact:** All running pods, all Helm releases, and all PVC data (MongoDB) were lost.
The GKE control plane (master) survived but the data plane is gone.

**Mitigation options:**
1. Re-enable billing in the GCP console: <https://console.developers.google.com/billing/enable?project=oran-lab>
2. Change `preemptible = false` in `terraform/variables.tf` and `terraform apply` to use
   standard VMs (higher cost but no surprise preemption).
3. Use `spot_instance_config { preemptible = true }` with `min_node_count = 1` autoscaling
   so GKE can scale back up automatically.
4. Add a `PodDisruptionBudget` and node anti-affinity to prevent all pods from landing on
   the same node (mitigates simultaneous preemption).

**Recovery procedure:**
1. Re-enable billing at the GCP console link above.
2. Wait for cluster to return to `RUNNING`.
3. Re-run `ansible-playbook ansible/playbooks/deploy.yml`.
   All three charts will re-deploy from scratch (namespaces and imagePullSecrets must
   be recreated first since they were lost with the nodes).
4. After MongoDB is Running, manually run `rs.initiate()` and seed the subscriber
   (see §26 for commands), until the Job-based init is implemented.

---

## 35. Files Modified (Part 6)

| File | Change |
|---|---|
| `helm/5g-core/templates/deployment-amf.yaml` | Added `amf-ngap-headless` headless Service for intra-cluster SCTP; updated header comment |
| `helm/ran/values.yaml` | `amfAddress`: `amf-ngap` → `amf-ngap-headless` |
| `helm/ran/templates/configmap-srsran-configs.yaml` | UE: `filename` → `/dev/stdout`; removed `netns = ue1` from `[gw]` |

