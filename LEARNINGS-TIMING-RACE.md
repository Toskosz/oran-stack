# O-RAN Near-RT RIC: Timing Race & Integration Learnings

## Overview

This document captures the root causes and fixes required to get an srsRAN CU/DU split gNB registered in the O-RAN Near-RT RIC e2mgr (`/v1/nodeb/states` endpoint). The stack uses Docker Compose with `ric-plt-e2mgr`, `ric-plt-rtmgr:0.9.6`, and `ric-plt-e2:6.0.5` (e2term).

---

## Issue 1: Wrong rtmgr Port in e2mgr Config

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

## Issue 2: Empty Message Type IDs in Routing Table

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

## Issue 3: Missing PlatformRoutes for Static Routing

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

## Issue 4: Keep-Alive Death Spiral (The Final Blocker)

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

## Required Restart Order ("RIC Reboot Dance")

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

## Key Port Map

| Container   | RMR Port | REST/HTTP Port | SCTP Port |
|-------------|----------|----------------|-----------|
| e2term      | 38000    | —              | 36421     |
| e2mgr       | 3801     | 3800           | —         |
| rtmgr       | 4560     | 3800           | —         |
| submgr      | 4560     | —              | —         |
| a1mediator  | 4562     | —              | —         |

---

## Verification Commands

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

## Files Modified

| File | Change |
|------|--------|
| `ric/config/e2mgr/configuration.yaml` | Fixed rtmgr port (8989→3800), increased keep-alive timers, set debug logging |
| `ric/config/rtmgr/rtmgr-config.yaml` | Added `messagetypes` (37 entries), added `PlatformRoutes` (8 static routes), set debug logging |
