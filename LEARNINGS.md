# O-RAN Stack Learnings

Accumulated debugging notes for the srsRAN + Open5GS + Near-RT RIC Docker stack.

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

Still crashing (RIC):
- `ric-e2term`, `ric-rtmgr` — separate RIC stack issue, not investigated

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

## 6. Files Modified This Session

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
