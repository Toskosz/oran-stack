# E2 Interface Stabilization Plan

## Problem Statement

The E2 interface between srs-CU and ric-e2term is broken. The CU successfully opens an SCTP
association and sends an E2SetupRequest, but never receives an E2SetupResponse. The root cause
chain is:

1. **e2term fails to respond to RMR keepalive messages** from e2mgr
2. After 120 s, e2mgr deletes the E2T instance
3. With no registered E2T, e2mgr cannot route the E2SetupResponse back to the CU
4. After 10 minutes, the CU times out and aborts the procedure (no retry mechanism)

### Failure Timeline (reconstructed)

| Time     | Event |
|----------|-------|
| 19:35:28 | ric-e2mgr starts |
| 19:35:48 | ric-rtmgr starts, pushes 12-entry RMR route tables |
| 19:37:47 | srs-CU connects via SCTP to `e2term:36421`, sends E2SetupRequest |
| 19:37:51 | rtmgr registers E2T via `AddE2T` for `10.4.1.23:38000` |
| 19:39:48 | e2mgr deletes E2T (`DeleteE2T`) after 120 s keepalive timeout — e2term never responded to `E2_TERM_KEEP_ALIVE_REQ` (msg type 1100) |
| 19:47:47 | srs-CU aborts E2 Setup procedure (10-min CU-side timer expired, never received E2SetupResponse) |

### Known-Good Facts

- SCTP association between srs-cu (`10.4.0.19:41256`) and e2term (`10.4.1.23:36421`) remains
  **ESTABLISHED** with zero errors, zero retransmits, 608 heartbeat packets exchanged.
- RMR TCP connections between e2term and e2mgr are **ESTABLISHED** in both directions.
- F1 interface (CU ↔ DU) is **working** — F1SetupRequest/Response completed at 19:38:34.
- All pods are Running with no unexpected restarts.
- No Kubernetes NetworkPolicies exist that could block traffic.

---

## Hypotheses

### H1 — RMR route table corruption: e2term cannot route keepalive responses back to e2mgr

**Likelihood**: High

**Evidence for**: rtmgr pushes routes containing pod hostnames (e.g.,
`ric-rtmgr-77fdd47bb9-h4fhs:4560`) instead of service names. DNS resolution fails for these
entries repeatedly in the logs. If the route entry for message type 1101
(`E2_TERM_KEEP_ALIVE_RESP`) points to a pod name that cannot resolve, e2term's RMR will
silently drop the response — and e2mgr will eventually time out and delete the E2T instance.

**Evidence against**: RMR TCP connections between e2term and e2mgr are ESTABLISHED; some
messages are being exchanged.

**Diagnostic steps**:

1. Exec into e2term pod:
   ```
   kubectl exec -n near-rt-ric deploy/ric-e2term -- cat /tmp/routetable/local.rt
   ```
2. Verify msg type `1101` (keepalive resp) routes to `ric-e2mgr:3801` (service name), not a
   pod name.
3. Exec into e2mgr pod:
   ```
   kubectl exec -n near-rt-ric deploy/ric-e2mgr -- cat /tmp/routetable/local.rt
   ```
4. Verify msg type `1100` (keepalive req) routes to `e2term:38000` (service name).

**Remediation**: Fix `PlatformComponents` in
`helm/near-rt-ric/templates/configmaps.yaml` (rtmgr config) to use Kubernetes service names
everywhere. Alternatively, add static seed route entries for keepalive message types in
`ric/config/e2term/dockerRouter.txt` and `ric/config/e2mgr/router.txt` using service names.

**F1 risk**: None. F1 uses direct SCTP between CU and DU; RMR is not involved.

---

### H2 — e2term image does not implement the keepalive RMR handler

**Likelihood**: Medium

**Evidence for**: e2term logs show zero evidence of processing any RMR keepalive message. The
keepalive handler (responding to msg type 1100 with msg type 1101) was added to OSC e2term in
a specific release. If the image predates or excludes this feature, the messages are silently
ignored.

**Evidence against**: The e2term image tag and OSC release notes have not been fully
cross-referenced yet.

**Diagnostic steps**:

1. Check the e2term image tag:
   ```
   grep -A2 'e2term' helm/near-rt-ric/values.yaml
   ```
2. Cross-reference with OSC `ric-plt/e2` release notes to confirm keepalive support.
3. Exec into e2term, inspect RMR receive counters for msg type 1100:
   ```
   kubectl exec -n near-rt-ric deploy/ric-e2term -- cat /tmp/rmr_counters 2>/dev/null || true
   ```

**Remediation**:
- **(a) Preferred**: Upgrade the e2term image to a version that implements keepalive handling.
- **(b) Workaround**: Disable keepalive-based deletion in e2mgr by setting
  `e2tInstanceDeletionTimeoutMs` to a very large value (e.g., `0` if the code supports
  disabling, or `86400000` for 24 h) in `ric/config/e2mgr/configuration.yaml`.

**F1 risk**: None.

---

### H3 — e2term RMR listener not fully operational on port 38000

**Likelihood**: Low-Medium

**Evidence for**: e2term config sets `volume=log` for logging but no `/log` volume is mounted
in the pod spec. This misconfiguration may affect e2term's initialization sequence and cause
the RMR subsystem to enter a degraded state where it accepts TCP connections but does not
process messages.

**Evidence against**: TCP connections to port 38000 are ESTABLISHED. RMR stats show non-zero
counters.

**Diagnostic steps**:

1. Confirm port 38000 is actually listening:
   ```
   kubectl exec -n near-rt-ric deploy/ric-e2term -- ss -tlnp
   ```
2. Check RMR environment variables in the running pod:
   ```
   kubectl exec -n near-rt-ric deploy/ric-e2term -- env | grep RMR
   ```
   Key variables: `RMR_SEED_RT`, `RMR_RTG_SVC`, `RMR_SRC_ID`.
3. Verify the seed route file is mounted and readable:
   ```
   kubectl exec -n near-rt-ric deploy/ric-e2term -- cat $RMR_SEED_RT
   ```

**Remediation**: Ensure `RMR_SEED_RT` points to a valid, mounted ConfigMap file. Fix the
`volume=log` misconfiguration by either removing it or adding an `emptyDir` volume at `/log`
(see H7).

**F1 risk**: None.

---

### H4 — Timing/ordering: e2mgr sends keepalive before e2term has a route table

**Likelihood**: Low

**Evidence for**: e2mgr starts at 19:35:28; rtmgr pushes routes at 19:35:48 (20 s later). If
e2mgr sends a keepalive request before e2term has received a route table from rtmgr, e2term's
RMR will discard the response. The existing 5-second init container startup delay
(`e2termStartupDelaySec`) is likely insufficient if e2term's RMR is not ready until rtmgr
completes its push.

**Evidence against**: `e2tInstanceDeletionTimeoutMs` is 120 s; rtmgr pushes within 20 s,
leaving ~100 s of margin. This is probably not the primary cause.

**Diagnostic steps**:

1. Find the exact timestamp of the first `E2_TERM_KEEP_ALIVE_REQ` in e2mgr logs.
2. Find the exact timestamp rtmgr pushed routes to e2term specifically.
3. Confirm that e2term's route table was loaded before the first keepalive arrived.

**Remediation**: Increase `e2termStartupDelaySec` in `helm/near-rt-ric/values.yaml` (currently
5 s). A value of 30–45 s gives rtmgr time to complete its first push. Alternatively, add an
init container that polls rtmgr's HTTP API until routes are available.

**F1 risk**: Negligible — a longer e2term startup delay only postpones when e2term opens its
SCTP port; the CU will simply retry the SCTP connect or wait.

---

### H5 — rtmgr PlatformRoutes missing keepalive and/or E2 Setup message types

**Likelihood**: High

**Evidence for**: rtmgr's `PlatformRoutes` in `rtmgr-config.yaml` controls which message types
get dynamic routes. If msg types 1100/1101 (keepalive) and 1200/1201 (E2 Setup) are absent,
rtmgr never creates routes for them. Components then rely solely on their seed route files,
which may also be missing these entries.

**Evidence against**: Seed route files exist for both e2mgr and e2term; they may already
contain the needed entries.

**Diagnostic steps**:

1. Check rtmgr config:
   ```
   grep -n 'messagetype\|1100\|1101\|1200\|1201' ric/config/rtmgr/rtmgr-config.yaml
   ```
2. Check e2mgr seed routes:
   ```
   grep -n '1100\|1101\|1200\|1201' ric/config/e2mgr/router.txt
   ```
3. Check e2term seed routes:
   ```
   grep -n '1100\|1101\|1200\|1201' ric/config/e2term/dockerRouter.txt
   ```
4. Check live route tables in both pods (same commands as H1).

**Remediation**: Add explicit `PlatformRoutes` entries for the missing message types in
`ric/config/rtmgr/rtmgr-config.yaml` and mirror the changes in the Helm ConfigMap at
`helm/near-rt-ric/templates/configmaps.yaml`. Also add static fallback entries to seed route
files.

**F1 risk**: None.

---

### H6 — rtmgr enters "not ready" loop and stops pushing route updates

**Likelihood**: Medium (consequence of primary failure; may also be a contributing cause)

**Evidence for**: After the DeleteE2T event at 19:39:48, rtmgr logs show repeated
`Application='' is not ready yet, waiting...`. It also fails wormhole connections to APPMGR
and A1MEDIATOR. Once stuck, rtmgr stops pushing route updates — any component that needs a
fresh route (e.g., after a CU reconnect) will never get one.

**Evidence against**: The "not ready" loop starts after E2T deletion, so it appears to be a
consequence. However, it prevents recovery without manual intervention.

**Diagnostic steps**:

1. Check which application registration is failing (`Application=''` suggests an empty name
   returned from a registration call):
   ```
   kubectl logs -n near-rt-ric deploy/ric-rtmgr --since=1h | grep -i 'not ready\|wormhole\|appmgr\|a1mediator'
   ```
2. Verify if restarting rtmgr clears the state:
   ```
   kubectl rollout restart -n near-rt-ric deploy/ric-rtmgr
   kubectl logs -n near-rt-ric deploy/ric-rtmgr -f
   ```

**Remediation**:
- Remove APPMGR and A1MEDIATOR from rtmgr's `PlatformComponents` if they are not deployed or
  not required for E2 routing.
- Add a liveness probe to ric-rtmgr in `helm/near-rt-ric/templates/deployments.yaml` that
  restarts the pod if it is stuck in "not ready" for more than 60 s.

**F1 risk**: None.

---

### H7 — e2term E2AP processing silently failing (log volume missing)

**Likelihood**: Medium (observability gap; may be masking other failures)

**Evidence for**: e2term config sets `volume=log` but no volume is mounted at `/log` in the
pod spec. All detailed E2AP processing logs (SCTP message receipt, ASN.1 decode, E2SetupRequest
handling, RMR send/recv per message) are written to `/log` and are lost. The actual E2AP
processing may be crashing or producing errors that are completely invisible.

**Evidence against**: The SCTP association remains ESTABLISHED, suggesting the process is alive
and handling the socket at some level.

**Diagnostic steps**:

1. Confirm `/log` is absent:
   ```
   kubectl exec -n near-rt-ric deploy/ric-e2term -- ls -la /log 2>&1
   ```
2. Check whether e2term supports `volume=stdout` in its config to redirect to stdout instead.

**Remediation**: Add an `emptyDir` volume named `log` and a corresponding `volumeMount` at
`/log` in the e2term Deployment in `helm/near-rt-ric/templates/deployments.yaml`. This is a
**prerequisite for debugging** and should be applied before any other change.

Example addition to the e2term Deployment template:
```yaml
# In volumeMounts:
- name: log
  mountPath: /log
# In volumes:
- name: log
  emptyDir: {}
```

Then tail logs in real time:
```
kubectl exec -n near-rt-ric deploy/ric-e2term -- tail -f /log/e2term.log
```

**F1 risk**: None. Only adds a volume to the e2term pod.

---

### H8 — e2mgr never processes E2SetupRequest due to missing RMR route for msg type 1200

**Likelihood**: High (closely tied to H1/H5)

**Evidence for**: For e2mgr to process an E2SetupRequest, e2term must: (1) receive the SCTP
message, (2) decode the ASN.1, (3) forward it as RMR message type 1200 to e2mgr. If e2term's
route table has no valid entry for type 1200 pointing to e2mgr, the message is silently
dropped. e2mgr's near-total silence in its logs (only 4 lines at startup) is consistent with
it never receiving any E2 message.

**Evidence against**: Directly overlaps with H1/H5; same investigation and remediation path.

**Diagnostic steps**: Check live route tables for message type 1200 (same as H1/H5).

**Remediation**: Same as H1/H5 — fix route tables to include E2 Setup message types.

**F1 risk**: None.

---

### H9 — Redis (ric-dbaas) connectivity issue prevents e2mgr from persisting state

**Likelihood**: Low

**Evidence for**: e2mgr uses Redis for storing NodeB state. `GET /v1/nodeb/states` returning
`[]` could mean Redis is unreachable. e2mgr logs show a Redis version compatibility warning at
startup.

**Evidence against**: ric-dbaas pod is Running normally. The version warning is a minor
informational log; it does not indicate a connection failure.

**Diagnostic steps**:

1. Verify Redis is reachable from e2mgr:
   ```
   kubectl exec -n near-rt-ric deploy/ric-e2mgr -- redis-cli -h ric-dbaas ping
   ```
2. Check Redis keyspace:
   ```
   kubectl exec -n near-rt-ric deploy/ric-dbaas -- redis-cli keys '*'
   ```

**Remediation**: If Redis is unreachable, check the `dbaas` service name and port in e2mgr's
`configuration.yaml`. This is unlikely to be the root cause but is quick to rule out.

**F1 risk**: None.

---

## Recommended Investigation Order

| Priority | Hypothesis | Rationale |
|----------|-----------|-----------|
| 1 | **H7** | Mount the missing `/log` volume to gain visibility into e2term internals. This is a prerequisite for all other debugging. |
| 2 | **H1 + H5** | Most probable root cause. Inspect live RMR route tables in both e2term and e2mgr; check rtmgr PlatformRoutes and seed files for keepalive and E2 Setup message types. |
| 3 | **H2** | Quick to verify — does e2term's image actually implement the keepalive handler? |
| 4 | **H8** | Covered by the H1/H5 route table inspection; no extra work. |
| 5 | **H3** | Verify RMR environment variables and port binding in e2term. |
| 6 | **H4** | Check timing of first keepalive vs. route table push; consider increasing startup delay. |
| 7 | **H6** | After fixing the primary cause, verify rtmgr recovers cleanly; add liveness probe if needed. |
| 8 | **H9** | Low probability; rule out with a single `redis-cli ping`. |

---

## F1 Protection Guardrails

Every proposed change must be validated against these rules before deployment:

1. **Never modify the `srs-cu` headless service** (`clusterIP: None`) — this is what allows
   F1 SCTP to bypass kube-proxy DNAT and reach the DU directly.
2. **Never change `duF1SetupHoldOffSec`** without fully understanding the CU startup sequence
   and the AMF registration window.
3. **Never restart srs-cu or srs-du pods** without first verifying the 5G core (AMF/SMF/UPF)
   is ready to accept re-registrations.
4. **Apply RIC changes first** — deploy changes to near-rt-ric, verify rtmgr route tables via
   its HTTP API, confirm e2term is reachable, then (if needed) restart only the CU.
5. **SCTP DaemonSet must remain untouched** — the `sctp-init` DaemonSet loads the kernel
   module required by both F1 and E2. Any change to it risks breaking both interfaces
   simultaneously.
6. **Validate route tables before restarting CU** — the CU has no E2 retry mechanism. Once it
   aborts the setup procedure, manual intervention is required. Ensure routes are correct before
   triggering a new E2SetupRequest.

---

## Change Log

| Date | Change | Author |
|------|--------|--------|
| 2026-04-12 | Initial plan created after full cluster diagnosis | OpenCode |
