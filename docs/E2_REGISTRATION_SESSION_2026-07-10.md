# E2 Registration Recovery — Session Report (2026-07-10)

## Executive summary

The deployment failed its E2 readiness gate because
`gnb_001_001_00019b` did not appear in e2mgr within 300 seconds. The
failure was not caused by basic SCTP reachability or by the e2term
`local-ip` using the primary Flannel address.

Two independent defects prevented E2 Setup from completing:

1. e2mgr had no stable `RMR_SRC_ID`, so sender-qualified RMR routes did
   not match its pod-hostname source identity.
2. DBAAS used stock `redis:6-alpine`, which does not provide the OSC SDL
   `MSETMPUB` command. e2mgr therefore failed the RNIB CONNECTED update
   and returned without sending E2SetupResponse.

After fixing both paths, the live result was:

- `/v1/nodeb/states` contained `gnb_001_001_00019b` with
  `connectionStatus: CONNECTED`.
- `/v1/e2t/list` contained the gNB in `ranNames`.
- e2mgr successfully sent RMR message type `12002`.
- e2term sent one SCTP response data chunk.
- The CU logged `E2 Setup procedure successful`.

The fixes are stored in the Helm and Ansible sources, so they are part of
future clean deployments rather than one-off live patches.

## Initial symptom

The `verify_stack` role repeatedly queried:

```text
GET http://localhost:3800/v1/nodeb/states
```

The response remained `[]`, and Ansible eventually failed:

```text
E2 gNB gnb_001_001_00019b did NOT register in e2mgr within 300s.
```

The first diagnostics established:

- e2mgr could open TCP to `ric-e2term:38000`.
- The CU and DU had completed F1 setup.
- The CU did not receive E2SetupResponse.

TCP connectivity to the RMR listener was useful evidence, but it did not
prove that RMR routes matched or that e2mgr could complete its RNIB
transaction.

## Investigation method

### 1. Verify each protocol boundary independently

The investigation separated the end-to-end path into:

```text
CU --SCTP/E2AP--> e2term --RMR/12001--> e2mgr
                                      |
                                      +--> RNIB/SDL in DBAAS
CU <--SCTP/E2AP-- e2term <--RMR/12002-+
```

For each boundary, the following evidence was collected:

- Kubernetes pod and service addresses.
- e2mgr `/v1/e2t/list` and `/v1/nodeb/states`.
- CU E2 logs and SCTP association state.
- e2term SCTP counters and E2AP logs.
- e2mgr/e2term RMR seed and dynamic route files.
- RMR source identities and send counters.
- rtmgr logs and generated routes.
- Redis keys and command errors.

### 2. Confirm the CU sent a real E2SetupRequest

CU logs showed:

```text
E2 connection to Near-RT-RIC on 10.200.3.4:36421 accepted
Generate RAN function definition ...
E2 Setup procedure aborted
```

SCTP state showed an established association:

```text
CU 10.200.3.2 <-> e2term 10.200.3.4:36421
```

A packet capture confirmed an SCTP DATA chunk with PPID 70 (`0x46`,
E2AP), procedure code 1, and KPM/RC RAN-function content. This ruled out
the hypothesis that the CU opened SCTP but never transmitted E2 Setup.

### 3. Inspect RMR identity and routes

rtmgr generated sender-qualified routes using stable service identities,
for example:

```text
mse|1101|ric-e2mgr:3801|...|ric-e2term:38000
```

e2mgr had no `RMR_SRC_ID`, so RMR used the Kubernetes pod hostname:

```text
ric-e2mgr-<replicaset>-<pod>:3801
```

That source did not match `ric-e2mgr:3801`. e2mgr RMR statistics
confirmed the consequence:

```text
target=ric-e2term:38000 open=0 succ=0 fail=0
```

After setting `RMR_SRC_ID=ric-e2mgr`, the same path changed to an open
endpoint with successful sends.

### 4. Follow E2 Setup through RNIB

After RMR identity was fixed, e2mgr received the setup request and created
RAN inventory, but still did not send E2SetupResponse. e2mgr logs exposed
the decisive error:

```text
ERR unknown command MSETMPUB
```

The deployed `redis:6-alpine` image lacked the OSC SDL Redis module.
e2mgr's CONNECTED-state update requires `MSETMPUB`. The resulting RNIB
error caused e2mgr to return before transmitting message type `12002`.

Replacing stock Redis with OSC DBAAS and loading its module completed the
RNIB update and allowed E2SetupResponse to be sent.

## Root causes and durable fixes

### Missing stable RMR source identity

Affected components now use stable service names:

```yaml
- name: RMR_SRC_ID
  value: ric-e2mgr
```

Submgr also uses `RMR_SRC_ID=ric-submgr`. rtmgr and e2term already use
stable identities.

Implementation:

- `helm/near-rt-ric/templates/deployments.yaml`

### DBAAS lacked the SDL Redis module

The chart now pulls:

```text
nexus3.o-ran-sc.org:10001/o-ran-sc/ric-plt-dbaas:0.6.5
```

It starts Redis with:

```yaml
args:
  - redis-server
  - --loadmodule
  - /usr/local/libexec/redismodule/libredismodule.so
  - --save
  - ""
  - --appendonly
  - "no"
```

This supplies `MSETMPUB`, allowing e2mgr to commit the CONNECTED state
and send E2SetupResponse.

Implementation:

- `helm/near-rt-ric/values.yaml`
- `helm/near-rt-ric/templates/deployments.yaml`

### RMR endpoint resolution

The internal `ric-e2term` service is headless:

```yaml
clusterIP: None
```

The service name therefore resolves directly to e2term's primary Flannel
pod IP, avoiding the RMR connection issue observed through the kube-proxy
ClusterIP.

### E2 logging

`volume=log` was relative to e2term's working directory and did not match
the volume mounted at `/log`. The effective configuration is now:

```text
volume=/log
trace=start
```

This makes E2AP processing visible in `/log/e2term.log`.

### Route and log-level corrections

The session also aligned:

- e2mgr seed routes with the rtmgr message-type mapping.
- rtmgr platform routes for SCTP connection failure (`1080`) and clear
  all (`1090`).
- e2mgr dynamic log configuration with integer `loglevel: 4`.

## Hypotheses ruled out

### e2term `local-ip` should be the OVS address

This is incorrect for the current design. `local-ip` is the advertised
RMR endpoint and must remain the primary Flannel pod IP. e2mgr does not
have a route to the secondary OVS subnet.

SCTP E2AP is separate and continues to use:

```text
CU 10.200.3.2 -> e2term 10.200.3.4:36421
```

e2term binds SCTP on all local addresses, so receiving E2AP through the
OVS interface while advertising the Flannel RMR address is intentional.

### TCP connect to port 38000 proves RMR is healthy

A successful TCP connection only proves listener reachability. RMR can
still fail because of source-qualified route mismatch, missing message
routes, or application-level processing errors.

### Increasing the registration timeout alone

The CU does not retry an aborted E2 Setup procedure. A longer Ansible
timeout cannot recover a setup request that was already dropped or a
response that e2mgr never sent.

## Deployment hardening added after recovery

### CU startup gate

The RAN chart now includes a `wait-for-e2t` CU initContainer. Before the
CU process can start, it polls:

```text
GET http://ric-e2mgr.<ric-namespace>.svc.cluster.local:3800/v1/e2t/list
```

It proceeds only when the JSON contains an `e2tAddress`. This closes the
startup race in which the CU sent its one E2SetupRequest before e2term
had registered with e2mgr.

Configuration:

```yaml
e2Readiness:
  enabled: true
  e2mgrUrl: http://ric-e2mgr.near-rt-ric.svc.cluster.local:3800
  pollIntervalSec: 5
```

Implementation:

- `helm/ran/values.yaml`
- `helm/ran/templates/deployments.yaml`
- `ansible/roles/deploy_ran/tasks/main.yml`

### Evidence-driven CU/DU recovery

Post-deploy verification now permits one controlled recovery attempt:

1. Wait normally for the expected gNB in `/v1/nodeb/states`.
2. If the gNB is absent, query `/v1/e2t/list`.
3. Restart nothing if no E2T exists; fail with RIC diagnostics instead.
4. If an E2T exists, restart the CU once so it reissues E2 Setup.
5. Wait for the replacement CU, then restart the DU once to restore F1
   against the new CU process.
6. Wait again for E2 registration.
7. If registration remains absent, stop and report diagnostics.

This is intentionally not an unbounded restart loop. It acts only when
the prerequisite E2 endpoint is present and is configurable through:

```yaml
verify_stack:
  e2_recovery_restart_enabled: true
  e2_recovery_rollout_timeout: 300s
  e2_recovery_wait_retries: 30
  e2_recovery_wait_delay: 10
```

Implementation:

- `ansible/roles/verify_stack/tasks/verify_e2.yml`
- `ansible/inventories/group_vars/all/vars.yml`

## Clean deployment expectations

A teardown followed by `ansible/playbooks/deploy.yml` is expected to
deploy the fixes because Ansible installs the charts from this repository.
The dependency order remains:

```text
5G core -> Near-RT RIC -> RAN -> verify -> xApp -> monitoring
```

The first-pass startup is protected by the CU E2T gate. The controlled
CU/DU recovery is a bounded fallback for srsRAN's non-retrying setup
behavior.

Requirements for reproducibility:

- The deployment host can pull the OSC DBAAS image from O-RAN SC Nexus.
- The repository revision containing these changes is the one used by
  Ansible.
- `deploymentStrategy: Recreate` remains enabled on the resource-limited
  worker and for static Multus addresses.
- e2term `local-ip` remains the primary Flannel pod IP.

## Verification commands

Confirm the expected DBAAS image:

```bash
kubectl -n near-rt-ric get deploy ric-dbaas \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
```

Confirm the SDL command is available:

```bash
kubectl -n near-rt-ric exec deploy/ric-dbaas -- \
  redis-cli COMMAND INFO MSETMPUB
```

Confirm e2mgr's stable RMR identity:

```bash
kubectl -n near-rt-ric exec deploy/ric-e2mgr -c e2mgr -- \
  sh -c 'echo RMR_SRC_ID=$RMR_SRC_ID'
```

Confirm E2T and gNB state:

```bash
kubectl -n near-rt-ric exec deploy/ric-e2mgr -c e2mgr -- \
  curl -sf http://localhost:3800/v1/e2t/list

kubectl -n near-rt-ric exec deploy/ric-e2mgr -c e2mgr -- \
  curl -sf http://localhost:3800/v1/nodeb/states
```

Expected outcomes:

- DBAAS image ends in `ric-plt-dbaas:0.6.5`.
- `MSETMPUB` is present.
- `RMR_SRC_ID=ric-e2mgr`.
- E2T has a non-empty endpoint and lists the gNB in `ranNames`.
- NodeB state contains `gnb_001_001_00019b` as `CONNECTED`.
- CU logs contain `E2 Setup procedure successful`.

## Files changed during the session

- `helm/near-rt-ric/values.yaml`
- `helm/near-rt-ric/templates/deployments.yaml`
- `helm/near-rt-ric/templates/configmaps.yaml`
- `helm/ran/values.yaml`
- `helm/ran/templates/deployments.yaml`
- `ansible/roles/deploy_ran/tasks/main.yml`
- `ansible/roles/verify_stack/tasks/main.yml`
- `ansible/roles/verify_stack/tasks/verify_e2.yml`
- `ansible/inventories/group_vars/all/vars.yml`

Related historical documents:

- `docs/E2_STABILIZATION_PLAN.md`
- `docs/LEARNINGS.md`
- `docs/STATUS.md`
