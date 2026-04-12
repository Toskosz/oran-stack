# O-RAN Lab Stack — Status

_Last updated: 2026-04-12_

---

## 1. Current Problems

### P1 — AMF Flapping (N2 / NGAP) — **UNRESOLVED**

The srsRAN CU-CP connects to Open5GS AMF, completes NGSetupRequest/Response successfully,
then loses the connection ~200–600 ms later. The cycle repeats every ~1–2 seconds indefinitely.

Observed in AMF logs:
```
gNB-N2 accepted[10.4.0.14] in master_sm module
[Added] Number of gNBs is now 7
gNB-N2[10.4.0.14] connection refused!!!
[Removed] Number of gNBs is now 6
```

Observed in CU logs:
```
N2: Connection to AMF ... was established
NGSetupResponse received
"AMF Connection Loss Routine" started...
```

The CU and AMF are on different GKE nodes. This problem occurs — and persists — even with
GKE Dataplane V2 (Cilium / anetd) enabled.

### P2 — E2 Agent Not Connecting — **INTERMITTENT**

The srsRAN DU has `enable_du_e2: true` configured with the correct e2term address
(`e2term.near-rt-ric.svc.cluster.local:36421`). In one observed run (with `all_level: debug`),
the E2 SCTP association was established and E2AP service model OIDs were generated. In all
other runs there are zero `[E2-DU]` log lines and no SCTP association to port 36421 in
`/proc/net/sctp/assocs`.

The inconsistency suggests the E2 agent initialises only when a specific condition is met
(possibly: cell scheduling must be active **and** F1 setup must have succeeded **before** a
certain startup window). The one successful run occurred with debug logging enabled and on a
fresh DU pod; subsequent restarts without debug logging produced no E2 activity.

### P3 — UE Never Attaches

The srsUE starts, establishes ZMQ connections to the DU, and reaches "Switching on" in the
NAS layer. It never acquires the cell (no PHY sync, no RRC connection). Root cause is P1:
the DU's cell scheduling activates only after a successful F1 setup, which in turn depends
on a stable CU, which depends on a stable N2 link to the AMF. With P1 unresolved the entire
RAN stack above the CU-CP cannot stabilise.

### P4 — Duplicate DU ID Rejection on DU Restart (**RESOLVED**)

When the DU pod is restarted (e.g. via `kubectl rollout restart`), the new pod sends
F1SetupRequest before the CU has cleaned up the previous DU's state. The CU rejects it with
`"Duplicate DU ID"` and `message-not-compatible-with-receiver-state`. The DU makes only one
retry by default and then gives up, leaving the cell un-served until a second manual restart.

**Fix:** srsRAN's F1 setup retry count is hardcoded to 1 and is not configurable. The fix
is in the DU Deployment's `wait-for-cu` initContainer
(`helm/ran/templates/deployments.yaml`). After confirming the CU process is reachable (DNS
+ UDP F1-U port probe), the container now waits an additional `duF1SetupHoldOffSec` seconds
(default: **30 s**, configurable in `helm/ran/values.yaml`) before allowing srsRAN to
start. The CU purges stale DU state ~23 s after SCTP COMM_LOST, so the 30 s hold-off
guarantees the cleanup window has fully elapsed before srsRAN makes its single F1Setup
attempt.

### P5 — e2term Config File Is Read-Only

The Near-RT RIC e2term startup script tries to run `sed -i` on files inside a ConfigMap
volume mount, which is always read-only in Kubernetes. The `sed` fails silently:
```
sed: couldn't open temporary file /opt/e2/config/sedKL88du: Read-only file system
```
The substitutions (pod IP, pod name) are not applied. e2term still starts and accepts SCTP
connections, so this is not currently blocking P2, but it means e2term runs with its
compiled-in defaults rather than the values the Helm chart intends.

### P6 — Preemptible Nodes Cause Cascading Restarts (**RESOLVED**)

The GKE cluster previously used preemptible (`e2-standard-4`) VMs. When a node was
preempted, all pods on it were deleted simultaneously. Because AMF, CU, and e2term
may land on different nodes, a single preemption event disrupted all three interface
layers (N2, F1, E2) at once and required a coordinated restart sequence (core → RIC →
RAN) to recover cleanly. This was observed to trigger the Duplicate DU ID problem (P4)
on every node preemption.

**Fix:** `preemptible_nodes = false` in `terraform/variables.tf`. The node pool now
provisions standard on-demand `e2-standard-4` nodes (`preemptible = false` in the
`google_container_node_pool` resource). Re-apply Terraform to replace the node pool.

---

## 2. Hypothesis

### H1 — SCTP Cross-Node Behaviour in GKE Dataplane V2

**Hypothesis:** GKE Dataplane V2 (Cilium eBPF) does not fully fix SCTP conntrack for
cross-node pod-to-pod traffic in the same way it fixes TCP. The AMF flapping (P1) was
initially attributed to iptables kube-proxy failing to handle SCTP state on the original
cluster (without Dataplane V2). After recreating the cluster with `ADVANCED_DATAPATH` the
flapping was transiently absent on the first successful run, but returned once the `sgmm`
node was preempted and a new node joined. This suggests either:

- Cilium's SCTP conntrack is correct but **something else** in the path is resetting the
  association (e.g. Open5GS AMF state machine bug triggered by a specific SCTP multi-stream
  negotiation parameter from srsRAN).
- Dataplane V2 helps for steady-state traffic but SCTP association setup across nodes still
  hits a race condition in the eBPF program during the initial 4-way handshake.
- The headless service DNS resolves to the correct pod IP, but the SCTP INIT ACK or
  COOKIE-ECHO is being dropped or re-routed on the new node before eBPF state is fully
  programmed.

### H2 — Open5GS AMF Rejects srsRAN SCTP Stream Count

**Hypothesis:** Open5GS AMF is closing the SCTP association because srsRAN negotiates
`max_num_of_ostreams: 30` in the INIT, but the AMF's internal NGAP state machine expects
exactly 1 outbound stream for the first NGAP message and treats anything else as an error.
The log line `gNB-N2[x.x.x.x] connection refused!!!` in Open5GS is emitted from
`amf-sm.c:1013`, which is the handler for an SCTP_COMM_LOST event — i.e. the AMF itself is
not actively refusing; it is reacting to the SCTP association being closed from the network
or from within the kernel. This shifts the blame back toward the datapath (H1) rather than
the application layer.

### H3 — E2 Agent Requires Active Cell Before Initialising

**Hypothesis:** The srsRAN DU E2 agent only starts after the cell scheduler is active
**and** at least one scheduling cycle has completed. In the one run where E2 connected, the
DU pod was fresh (no prior state), debug logging was on (which adds startup latency), and
the init containers' DNS wait guaranteed the CU was fully ready before F1 Setup. In all
other runs the DU pod was restarted mid-flight while the CU still had stale state, causing
F1 Setup to fail (P4) and the cell scheduler to never activate — which in turn prevented
the E2 agent from starting.

---

## 3. Facts

| # | Fact | Source |
|---|------|--------|
| F1 | GKE Dataplane V2 (`ADVANCED_DATAPATH`) uses Cilium eBPF (`anetd`). `anetd` is running on both nodes (verified via `kubectl get pods -n kube-system`). | kubectl |
| F2 | AMF flapping (`connection refused!!!`) occurs with cross-node CU↔AMF placement even on Dataplane V2. It was absent for ~10 minutes after first deploy, then returned after node preemption. | AMF logs |
| F3 | The `amf-ngap-headless` service is `clusterIP: None` (headless). DNS resolves directly to the AMF pod IP, bypassing kube-proxy DNAT entirely. | kubectl |
| F4 | The SCTP 4-way handshake completes (NGSetupRequest → NGSetupResponse received), proving the connection reaches application layer. The AMF logs `COMM_LOST` ~200–600 ms later. | CU + AMF logs |
| F5 | In the one run where E2 worked, `[E2-DU]` log lines appeared, SCTP association to `10.8.7.148:36421` (e2term ClusterIP) was established, and E2AP RAN function OIDs for KPM and RC were generated. | DU logs + `/proc/net/sctp/assocs` |
| F6 | In all other DU runs `/proc/net/sctp/assocs` shows only the F1AP association (to CU port 38472). There are no `[E2-DU]` log lines and no error messages about E2. | kubectl exec |
| F7 | The DU config is rendered correctly: `enable_du_e2: true`, `addr: e2term.near-rt-ric.svc.cluster.local`, `port: 36421`, `bind_addr: <pod IP>`. The pod IP is a real IP (sed substitution works). | kubectl exec cat |
| F8 | F1 Setup fails with "Duplicate DU ID" if the new DU pod races ahead of the CU cleaning up the old DU. The CU cleans up the old DU ~23 seconds after SCTP COMM_LOST. The DU's internal retry count is hardcoded to 1 (not configurable). **Fixed (P4):** `wait-for-cu` initContainer now holds off 30 s after the CU is reachable, outlasting the cleanup window. | CU logs / `helm/ran/values.yaml` |
| F9 | `apk add gettext` fails silently inside the GKE init containers (no internet egress to Alpine mirrors). This was the original cause of `${POD_IP}` not being substituted. Fixed by replacing `envsubst` with `sed`. | init container logs |
| F10 | The UE never reaches cell sync. It reaches NAS "Switching on" and stops. No PRACH activity is visible in DU logs. Root cause is P1 → P4 cascade. | UE + DU logs |
| F11 | Node pool now uses standard (on-demand) `e2-standard-4` nodes (`preemptible = false`). Previously preemptible — preemption was observed once during a session, causing `sgmm` to be replaced and triggering P1 + P4 simultaneously. P6 resolved. | terraform/variables.tf |
| F12 | e2term `sed -i` substitutions fail at startup (read-only ConfigMap volume). e2term is still functional (accepts SCTP). The Helm chart's intent to inject pod IP / pod name is not applied. | e2term logs |
| F13 | Open5GS AMF NRF registration, UDM/AUSF/NSSF subscriptions, and all SBI NF-to-NF links are healthy and stable. The 5G core NFs other than the AMF SCTP path are not the problem. | AMF logs |
| F14 | The Near-RT RIC internal RMR mesh (e2term ↔ e2mgr ↔ rtmgr ↔ submgr) is healthy. RMR heartbeat counts increment normally. No internal RIC errors observed. | e2mgr + e2term logs |

---

## 4. VPS vs GKE — Would This Be Easier on VMs?

**Short answer: yes, significantly, for a lab.**

### What gets easier on VPS

**SCTP works without fighting the dataplane.**
On a plain Linux VM (Debian, Ubuntu, etc.), SCTP is a first-class kernel feature. There is
no container network plugin, no eBPF overlay, no conntrack translation layer between two
pods. srsRAN CU and Open5GS AMF would run as processes (or in Docker with `--network=host`)
and their SCTP associations would be handled by the vanilla kernel TCP/IP stack with
`CONFIG_IP_SCTP=y`. The AMF flapping problem (P1) would almost certainly not exist.

**No node preemption.**
A VPS does not disappear mid-session. Preemptible GKE nodes were the direct cause of the
cascading restart problem (P6) and contributed to the Duplicate DU ID race (P4). P6 has
been resolved by switching to standard on-demand nodes; however on a VPS services stay
up until you restart them with no GCP infrastructure dependency.

**No container networking overhead for SCTP.**
ZMQ (used by srsRAN for the simulated radio between DU and UE) is TCP-based and works fine
in Kubernetes. SCTP (used by N2, F1, E2) is the problematic protocol in every container
network plugin tested so far.

**Simpler config management.**
On VMs you can use the original srsRAN `.yml` / `.conf` files directly with real hostnames
or IPs. There is no ConfigMap templating, no init container `envsubst`/`sed` pipeline, no
imagePullSecret management.

**Cheaper for always-on lab use.**
Two `e2-standard-4` GKE nodes (4 vCPU, 16 GB each) cost ~$0.17/hour each (preemptible) or
~$0.57/hour (on-demand). A comparable VPS (e.g. Hetzner CX41: 8 vCPU, 16 GB) costs ~$0.03–
0.06/hour. For a continuously-running lab the cost difference is significant.

### What GKE does better

| Concern | GKE | VPS |
|---------|-----|-----|
| Declarative infra | Terraform + Helm — reproducible from scratch | Manual or Ansible against static IPs |
| Scaling | Add nodes, pods reschedule automatically | Manual VM provisioning |
| Rolling updates | `helm upgrade` with zero-downtime for stateless NFs | Stop, update, restart |
| Observability | Prometheus / GMP built-in, log forwarding to Cloud Logging | Self-hosted or nothing |
| Image distribution | Docker Hub pull works everywhere | Same — no advantage |
| SCTP | Requires Dataplane V2 and careful service design; still unreliable in testing | Works out of the box |

### Recommendation

For a **protocol-correct, always-on lab** where SCTP reliability is the priority:
use 2–3 VPS instances (1 for 5G core, 1 for RAN, 1 for RIC) with Docker Compose or bare
processes. The existing Helm charts and Ansible roles can be adapted to Compose with minimal
effort — the config templates and image names are already parameterised.

For a **reproducible, cloud-native lab** where the goal is to practice Kubernetes-native
O-RAN deployment: stay on GKE with standard (non-preemptible) nodes (now the default) and
add a `PodAntiAffinity` rule to keep CU and AMF on the same node until the cross-node SCTP
issue is fully understood.

A hybrid is also viable: run the 5G core and RIC on GKE (stateless HTTP/gRPC SBI is well-
suited to Kubernetes), and run srsRAN CU/DU/UE as Docker Compose on a single VPS that
connects to the GKE cluster via a VPN or `kubectl port-forward`. This isolates the SCTP
problem to a single hop (VPS process → GKE NodePort → AMF pod) which is easier to debug
and avoids cross-node SCTP entirely.
