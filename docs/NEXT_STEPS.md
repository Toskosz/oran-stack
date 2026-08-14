# Next Steps

Forward-looking work for the O-RAN lab stack. Keep this file for planned changes, not session incident reports.

---

## Dynamic gNB lifecycle — stop hardcoding `e2_node_id`

### Context

Today the stack assumes **one static gNB**. Ansible `xapp.e2_node_id` (and `verify_stack` E2 gates) expect a single inventory name, typically `gnb_001_001_00019b`, derived from PLMN `001/01` plus srsRAN’s default `gnb_id=411` (`0x19b`). The xApp is started with that ID baked in via Helm; sample xApp code still has a TODO to discover E2 nodes from SubMgr instead of taking a fixed CLI flag.

That works for the single-gNB lab. It does **not** work if gNBs are spawned and removed dynamically.

### Practical recommendation

1. **Keep `e2_node_id` as a single-lab default** for the one-gNB testbed. Do not treat `vars.yml` as a live inventory.

2. **For dynamic gNBs, move the contract to:**
   - **Orchestrator assigns `gnb_id`** (and unique networking) → predicts `ranName` as `{type}_{mcc}_{mnc}_{hex(gnb_id)}[_{instance}]`.
   - **xApp / controller lists e2mgr and reconciles subscriptions** — treat `GET /v1/nodeb/states` (and E2T `ranNames`) as source of truth:
     - on add: subscribe when a node becomes `CONNECTED`
     - on remove: unsubscribe / drop the ID when it disconnects or disappears

3. **Do not grow a static list only in `ansible/inventories/group_vars/all/vars.yml`.** That file is deploy-time config, not a runtime registry.

### Also required beyond the ID string

- Unique `gnb_id` per live gNB (never reuse default `411` for two concurrent nodes).
- Unique Multus/OVS IP and NAD allocation (today CU/DU E2 IPs are fixed). Blocked on cluster-wide IPAM — see **Professionalize the workload network**.
- RIC lifecycle: E2 Setup creates RNIB entries; teardown must leave clean disconnect state so xApps do not target ghosts.
- Verification: replace “wait for this one ID” with “expected set CONNECTED” or “at least N nodes”.

---

## Near-RT RIC RMR / indication path — durable network fix

### Context

KPM subscribe can succeed (`Successfully subscribed`, SubMgr REST OK) while the xApp
never sees `RIC Indication Received`. That is almost always a **RIC routing /
deploy** problem, not an xApp logic bug. Upstream srsRAN `oran-sc-ric` mostly
avoids this via Docker Compose + `rtmgr_sim` and static routes; this K8s stack
uses real RTMgr/AppMgr/SubMgr and hits several platform pitfalls.

The small `xAppBase` pending-ID race fix is separate defensive coding. It does
**not** replace fixing delivery of RMR msg type `12050` (RIC Indication).

### What must stay correct in config (product fix)

Land these in Helm / `ric/config` so a cold deploy works without Ansible
band-aids:

1. **SubMgr → RTMgr NBI port `3800`**
   - `ric-plt-rtmgr:0.9.6` ignores `local.host` and binds REST on **3800**, not
     `8989`.
   - Files: `helm/near-rt-ric/templates/configmaps.yaml`,
     `ric/config/submgr/submgr-config.yaml`.

2. **Stop A1Mediator-triggered `newrt` wipes of `mse|12050|<subid>`**
   - rtmgr hardcodes a lookup for Platform component `A1Mediator`. If that
     name is missing from `PlatformComponents` / `rt.json` Pcs, it
     redistributes a full `newrt` every ~10s and wipes indication routes.
   - Keep `A1Mediator` (`fqdn: ric-a1mediator`, port `4562`) in
     PlatformComponents. Continue omitting `A1_POLICY_*` messagetypes until
     A1 policy traffic is actually needed.
   - Files: rtmgr configmap + `ric/config/rtmgr/*`.

3. **Explicit `RIC_SUB_*` / `RIC_SUB_DEL_*` platform routes**
   - SUBMAN must own subscribe/delete request toward the meid and receive
     RESP/FAILURE. Incomplete platform routes break or strand subscriptions.

4. **Stable RMR identities**
   - RTMgr `RMR_SRC_ID` must be a resolvable FQDN (e.g. `ric-rtmgr.<ns>`), not
     a bare name that fails route ACKs.
   - xApp `XAPP_IP` must be the **RMR Service FQDN** registered with AppMgr
     (`service-ricxapp-<release>-rmr.<ns>`), never a pod IP — otherwise RTMgr
     route create returns HTTP 400.

5. **RAN E2 attachment side + metrics that exist**
   - Lab path uses CU-UP E2 (`enable_cu_up_e2: true`, CU-CP E2 off) where that
     matches the connected node id.
   - xApp values (`simple-mon.yaml`) must request KPM style/metrics the gNB
     actually reports.

### Hard rule

**Do not restart E2Term after the xApp has subscribed.** That drops SCTP; srsRAN
CU often will not re-setup E2, leaving the gNB `DISCONNECTED` and orphaning the
just-installed `12050` route.

### Ansible glue to retire once config is solid

`deploy_xapp` currently compensates for RTMgr lifecycle gaps:

- Wait for AppMgr register → restart RTMgr → wait for route push to xApp →
  restart xApp so it subscribes against a stable table.
- Optionally re-POST `/ric/v1/handles/xapp-subscription-handle` to keep
  `12050` alive while residual `newrt` wipes still occur.

**Next step:** after (1)–(4) are committed and a clean `deploy.yml` run shows
stable `Entries` for xApp + e2term with continuous `RIC Indication Received`
**without** the re-POST loop, remove or gate that workaround. Prefer fixing
RTMgr/A1 config over perpetual route re-install.

### How to tell network vs xApp

| Observation | Fix where |
|-------------|-----------|
| Subscribed + ID mapping logged, but never `RIC Indication Received` | RIC/deploy (routes, A1 wipe, AppMgr/XAPP_IP, E2Term) |
| RMR delivers `12050` but callback never runs | xApp map race (`_pending_event_instance_ids`) |

### Acceptance

Cold deploy (no manual kubectl): gNB `CONNECTED` → xApp registers → SubMgr
subscribe OK → RTMgr shows `12050` routes to xApp and e2term → xApp logs
periodic `RIC Indication Received` for several report periods with no
subscription-handle re-POST and no E2Term restart.

---

## Second xApp on a live RIC — unique release + RTMgr learn plan

### Context

Today Ansible only deploys one xApp release (`helm_releases.xapp` →
`r4-simple-mon`) into `ricxapp`. A **different** xApp (this repo or a separate
Ansible project) can join the **same** already-running Near-RT RIC, but it
shares AppMgr / RTMgr / SubMgr / E2Term with `simple-mon`. There is no isolated
RMR plane.

A plain “Helm install + wait for pod Ready” is not enough: the new xApp often
registers and even gets `Successfully subscribed` while never seeing
`RIC Indication Received`, for the same RTMgr lifecycle gaps documented above.

### Requirements for the second xApp

1. **Unique Helm release name** (and therefore unique K8s Service / RMR
   identity). Do **not** reuse `r4-simple-mon` — that upgrades/overwrites the
   existing release.
   - RMR Service FQDN pattern:
     `service-ricxapp-<release>-rmr.<namespace>` (e.g. namespace `ricxapp`).
2. **`XAPP_IP` must be that Service FQDN**, never a pod IP (RTMgr route create
   returns HTTP 400 otherwise).
3. Correct SubMgr / AppMgr URIs on the shared RIC
   (`ric-submgr` `:8088`, `ric-appmgr` register).
4. E2 node id + KPM style/metrics the connected gNB actually advertises (lab
   path is typically CU-UP). Same-node dual subscriptions may succeed or
   conflict depending on SubMgr/RAN — treat that as an explicit test, not an
   assumption.
5. **Do not restart E2Term** as part of bringing the second xApp up.

### Plan: RTMgr learning the new xApp

RTMgr only syncs xApps from AppMgr at **startup**. After the new xApp registers
with AppMgr, RTMgr will not reliably push platform routes to the new endpoint
until it reloads AppMgr’s inventory.

**Required sequence (deploy playbook for the second xApp):**

1. Install the new release (unique name) and wait until AppMgr register succeeds
   (`appmgr register` + `HTTP 201` in xApp logs).
2. **Resync RTMgr** so it learns the new xApp from AppMgr:
   - **Lab workaround (current):** `kubectl rollout restart deployment/ric-rtmgr`
     in the RIC namespace, wait for rollout, then wait for RTMgr logs showing
     successful `Update Routes to Endpoint` for the **new** Service FQDN
     (`…:4561` or whatever RMR port the chart uses).
   - **Product fix (prefer):** a real hot-reload / AppMgr→RTMgr notify path so
     a second xApp does **not** require restarting RTMgr on a live network.
3. Only after that route push: let the new xApp subscribe (restart the new xApp
   if it subscribed too early against an empty/stale table).
4. Confirm RTMgr installed subscription indication routes (`12050`) toward both
   the new xApp endpoint and `ric-e2term` (same class of checks as
   `deploy_xapp` for `Entries` / SubManager add success).
5. **Account for blast radius:** restarting RTMgr rebuilds RMR tables for the
   whole RIC. Existing `r4-simple-mon` indication routes (`mse|12050|<subid>`)
   can drop until SubMgr/handle path reinstalls them. Either:
   - re-run / share the existing subscription-handle re-POST heal for
     `simple-mon`, or
   - land the A1Mediator/`newrt` wipe fix above so residual wipes stop, and
   - verify both xApps still log `RIC Indication Received` after the resync.
6. Until A1/`newrt` is fixed, optionally re-POST
   `/ric/v1/handles/xapp-subscription-handle` for the **new** subscription id
   the same way `deploy_xapp` does for `simple-mon`.

### Out of scope for a naive second playbook

- Reusing this repo’s `deploy_xapp` as-is: it is hard-wired to
  `helm_releases.xapp` / `simple-mon` waits and will not gate the second
  release.
- Assuming the second Ansible can ignore RTMgr because “the network is already
  up” — platform routes for a **new** AppMgr registration are still the
  missing step.

### Acceptance

On a live stack that already has `r4-simple-mon` receiving KPM:

- Second xApp deploys under a **distinct** release/Service name.
- After the RTMgr learn step, RTMgr shows route updates for the new endpoint.
- New xApp logs `Successfully subscribed` and periodic
  `RIC Indication Received`.
- Existing `simple-mon` still receives indications (or recovers within the
  documented heal window) **without** an E2Term restart.

---

## Investigate `enable_cu_cp_e2` on newer srsRAN

### Context

The lab currently runs CU-UP E2 only (`enable_cu_up_e2: true`, `enable_cu_cp_e2: false`
in `helm/ran/templates/configmap-srsran-configs.yaml`). That choice came from srsRAN
**25.10**: the CU-CP KPM provider registered an E2 node but advertised **no usable
metrics**, so `simple-mon` subscriptions against CU-CP failed. CU-UP does expose
metrics the xApp requests (e.g. `DRB.PacketSuccessRateUlgNBUu`).

Newer srsRAN releases may have filled in CU-CP KPM (or RC) support. If they have,
re-enabling CU-CP E2 (alone or alongside CU-UP/DU) could unlock control-plane
metrics and simplify node-id expectations.

### Investigation

1. **Diff KPM providers** between the image/tag this stack builds
   (`dockerfiles/Dockerfile.srsran` / Chart `appVersion`) and current upstream
   `srsRAN_Project` release notes + source under CU-CP vs CU-UP E2/KPM.
2. **Catalog advertised metrics** for CU-CP when `enable_cu_cp_e2: true` (E2 Setup
   RAN function description / OID list in CU logs and e2mgr node inventory).
3. **Smoke test** on a throwaway deploy: flip to `enable_cu_cp_e2: true` (try with
   UP off first, then both on), note the e2mgr `ranName`, point
   `simple-mon.yaml` / `xapp.e2_node_id` at that ID, and subscribe to any metrics
   CU-CP actually lists.
4. **Decide policy** for the chart:
   - Keep CU-UP-only if CU-CP still has an empty KPM set.
   - Or document a version gate (e.g. “from release X, prefer CU-CP for …”) and
   update Helm defaults + Ansible `e2_node_id` accordingly.
5. **If both CP and UP E2 are viable**, document which node id xApps must use and
   whether dual agents cause duplicate/conflicting RNIB entries.

### Acceptance

Either (a) a short note here / in LEARNINGS that CU-CP KPM remains empty on the
pinned version (no chart change), or (b) Helm + xApp values updated to a proven
CU-CP metric set with cold-deploy indications working against the CU-CP node id.

---

## UPF: sair de `hostNetwork` para attachment de produção

### Context

O UPF Open5GS hoje usa `hostNetwork: true` e `privileged` para criar `ogstun`
no namespace de rede do nó, deixar o iptables do worker ver a TUN e receber
GTP-U (UDP 2152) no IP do host. Isso faz o plano de usuário funcionar no lab
(`10.45.0.0/16` → DNN `internet`). Não é o desenho de produção.

O próprio chart (`helm/5g-core/templates/deployment-upf.yaml`) chama isso de
aproximação de laboratório.

### What production looks like

- Interfaces 3GPP próprias (N3 GTP-U, N4 PFCP, N6 DNN), não o IP primário do worker.
- Multus + SR-IOV / DPDK / VF — não `hostNetwork`.
- Encaminhamento GTP no kernel (`gtp5g`), eBPF ou user-space DPDK — não TUN + iptables do nó.
- Pod sem `privileged` / `NET_ADMIN` no host.

### Next step

This is step 4 of **Professionalize the workload network**. Do not start here
before cluster-wide IPAM and NF config-from-allocated-IP work for N2/F1/E2.

1. Documentar o gap lab vs produção (este item).
2. Avaliar UPF com NAD dedicado (N3/N6) em vez de `hostNetwork` — OVS bridges
   `n3br` / `n6br` on current GCP/`e2-*` hardware; SR-IOV only when the
   provider has VFs (private cloud / Proxmox).
3. Só então retirar `privileged` + `hostNetwork` do chart.

### Acceptance

GTP-U do CU chega ao UPF por interface N3 anexada (não IP do nó); `ogstun` /
forwarding não dependem do netns do worker; Pod UPF deixa de ser `hostNetwork`.

---

## Professionalize the workload network

### Context

The lab keeps SCTP (N2, F1-C, E2AP) off Flannel and kube-proxy via Multus + OVS
bridges (`n2br`, `f1cbr`, `e2br`) and **static** secondary IPs in Helm values
and Multus `ips:` annotations (`secondaryNetworks.*.*IP` in `vars.yml` /
chart values). That split is correct for long-lived SCTP. It is not an elastic
address plan: replica count is effectively 1, peer IPs are copied into CU/DU/AMF
config by hand, and a second gNB cannot join without editing the same numbers.

NADs created by `kubeadm_control_plane` already declare `host-local` IPAM on
each `10.200.x.0/24`, but pods override it with pinned addresses. `host-local`
is per-node: two pods on `cp1` and `w1` can receive the same IP on the VXLAN
L2. The static pins exist to avoid that collision.

Related gaps:

- NAD and OVS bridge lifecycle live in Ansible (`provision.yml` /
  `ovs_vxlan`), not in Nephio packages. Ansible is supposed to own hosts;
  GitOps is supposed to own network functions.
- Multus (manifest `master`) and the Ubuntu Open vSwitch package are unpinned
  (see `docs/NETWORK_PRESENTATION.html` software inventory).
- UPF uses `hostNetwork` (section above).
- Dynamic gNB (first section) cannot allocate unique Multus IPs.
- No verify Job checks that secondary interfaces or SCTP associations exist.
- Deploy providers are **GCP VM create** or **pre-existing BYO hosts**. There
  is no first-class private-cloud path. BYO (`hosts.ini`, `HOME_LAB_DHCP.md`)
  assumes machines already exist; it does not provision them.

### Invariant

Do not put N2 / F1-C / E2AP back on ClusterIP or kube-proxy. Elasticity is a
new NF instance with a unique 3GPP identity and a unique secondary IP, not
`replicas: N` on one address. HTTP/2 (SBI), RMR, and UDP (F1-U, N4) may stay
on the primary CNI.

### Sequence (do in order)

1. **Cluster-wide IPAM** — Whereabouts on the existing OVS NADs, or the Nephio
   resource-backend IPAM already pulled by `bootstrap-nephio.yml` and not used
   for these pools. Reserve a small well-known range for AMF N2 and e2term E2;
   allocate the rest of each `/24` to RAN. Drop `"ips": [...]` from pod
   annotations. Do not use `host-local` across VXLAN.

2. **NF config from the allocated IP** — today the same address is duplicated
   in the Multus annotation, container env, and OCUDU/Open5GS YAML. After IPAM,
   an init/entrypoint must read `k8s.v1.cni.cncf.io/network-status` and
   `envsubst` bind/peer addresses before the NF starts. GitOps alternative:
   Nephio IPAM fills kpt setters before Config Sync applies. Without this step,
   removing static `ips:` breaks N2/F1/E2 (CU still dials `10.200.1.2`).

3. **NADs in GitOps + pin CNI** — move NetworkAttachmentDefinition manifests
   into `packages/blueprints` (or a `workload-cni` package). Ansible keeps
   kernel modules, host OVS, and VXLAN tunnels. Pin Multus and Open vSwitch
   versions. A PackageVariant that clones a gNB must be able to request
   another NAD/pool without re-running `provision.yml`.

4. **UPF off `hostNetwork`** — add `n3br` / `n6br` OVS bridges (same pattern
   as SCTP). Attach N3 (GTP-U) and N6 (DNN); keep TUN inside the pod netns;
   leave N4 (PFCP/UDP) on ClusterIP. Drop `hostNetwork` so a second UPF does
   not collide on host UDP/2152. SR-IOV / `gtp5g` / DPDK only when the
   hypervisor exposes VFs — not on GCP `e2-*`. Details and acceptance: **UPF**
   section above.

5. **`verify-net` Job** — fail the deploy if a required NAD IP is missing, if
   `ovs-vsctl` has no VXLAN per bridge, if `/proc/net/sctp/assocs` lacks N2 /
   F1 / E2 `ESTABLISHED`, or if AMF and CU are not on the same `n2br` L2.
   `verify-e2` / `verify-ue` do not cover this.

6. **Dynamic gNB** — only after (1) and (2). PackageVariant per gNB (`gnb_id`
   + IPs from the pool). xApp/e2mgr list `CONNECTED` nodes. Do not grow a
   static list in `vars.yml`. Details: first section.

7. **NetworkPolicy on Flannel only** — restrict SBI, RMR, and metrics on the
   primary CNI. Kubernetes NetworkPolicy does not see Multus/OVS interfaces;
   N2/F1/E2 isolation stays “one bridge per 3GPP reference point”. Document
   that split; do not pretend one policy model covers both planes.

### Defer until hardware or a later milestone

| Item | Why not now |
|------|-------------|
| SR-IOV / DPDK / VF | GCP `e2-*` and typical home NICs have no VFs |
| BGP instead of OVS VXLAN | Replaces the underlay; VXLAN already isolates SCTP |
| AMF Set + SCTP load balancer | Needs an SCTP-aware LB; GCP forwarding rules do not |
| e2term pool | Needs IPAM plus e2mgr dispatching nodes |
| HPA on AMF / CU / DU | Still wrong for SCTP identity |

### Private cloud (Proxmox as the first target)

GCP (`gcp-vm-create.yml` / `GCP_RUNBOOK.md`) provisions VMs. BYO only consumes
already-installed Ubuntu hosts. A professional network plan needs a **third
provider**: private cloud, with Proxmox as the first implementation.

Treat it as a peer of GCP, not as another `hosts.ini`:

1. **Provision VMs** — Ansible (e.g. `community.general.proxmox` /
   `community.proxmox`) or Terraform creates `cp1`, `w1`, and `mgmt` with
   cloud-init, SSH keys, and sizes analogous to `e2-standard-2` /
   `e2-standard-4`. Generate inventory the same way GCP does. Do not require
   operators to pre-create guests by hand.

2. **Underlay networking** — map Proxmox bridges/VLANs (and later SDN) to
   kubeadm node IPs so OVS VXLAN outer addresses stay stable. Private-cloud
   DHCP/dnsmasq must reserve those IPs (same failure mode as
   `HOME_LAB_DHCP.md`, but owned by the hypervisor). Optional second bridge
   for cluster underlay vs management.

3. **Runbook** — `docs/PROXMOX_RUNBOOK.md` (or a provider-neutral private-cloud
   runbook) covering create → provision → GitOps → teardown, parallel to
   `GCP_RUNBOOK.md`. Keep `provision.yml` / Nephio playbooks provider-agnostic;
   isolate Proxmox to a create/teardown role plus inventory.

4. **Hardware that GCP `e2-*` cannot offer** — Proxmox is the path to PCI
   passthrough / SR-IOV for UPF N3/N6 and, if needed, RAN user plane. Gate
   that on the IPAM + NAD work above; do not special-case SR-IOV only on
   Proxmox while GCP remains `hostNetwork`.

5. **Keep GCP working** — private cloud is an additional target. Provider
   differences (storage, extra disks, security groups vs Proxmox firewall,
   nested virt) belong in the create role and the runbook, not in Helm
   charts.

Other private-cloud APIs (oVirt, Harvester, OpenStack) should reuse the same
inventory contract once Proxmox lands.

### Acceptance

- Secondary IPs come from cluster-wide IPAM; Helm values no longer pin
  `secondaryNetworks.*.*IP` for RAN.
- AMF, CU, DU, and e2term bind and dial the addresses actually attached by
  Multus.
- NAD manifests are versioned in GitOps; Multus and OVS versions are pinned.
- UPF GTP-U uses an attached N3 interface, not the worker node IP.
- `verify-net` gates cold deploy.
- Cold deploy succeeds on **GCP and Proxmox** from a documented runbook
  without hand-built VMs or hand-edited secondary IPs.
- A second gNB PackageVariant can take unique Multus IPs without editing
  `vars.yml`.
