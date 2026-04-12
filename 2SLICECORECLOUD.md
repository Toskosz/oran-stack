# Plan: Multi-Slice 5G Core + Multus/macvlan Networking on GKE

## Context Summary

**Current state:**
- Single-slice 5G core (1 SMF, 1 UPF) — SST=1 only
- UPF uses `hostNetwork: true` as an approximation (no secondary NIC)
- SMF→UPF PFCP and UPF GTP-U go over the pod network / host network
- All NF configs embedded in one `configmap-nf-configs.yaml` via `envsubst`
- One global `SMF_SUBNET4` / `SMF_SUBNET6` / `UPF_IP` env var set

**Target state:**
- 2 slices (SST=1 / SST=2), each with its own SMF+UPF pair
- Multus installed on GKE nodes via DaemonSet; macvlan secondary CNI
- Two macvlan NADs: `n3network` (`10.10.3.0/24`) and `n4network` (`10.10.4.0/24`)
- UPF pods get secondary NICs for N3 (GTP-U) and N4 (PFCP) — drop `hostNetwork: true`
- AMF and NSSF updated to advertise both slices
- MongoDB seed updated to include a second subscriber on slice 2

---

## Step 1 — Install Multus on GKE

**Approach:** Multus CNI is a cluster-level component (installs in `kube-system`). A
standalone `kubectl apply` during Ansible provisioning is cleaner than embedding it
in the `5g-core` chart.

- In `ansible/roles/gke_provision/tasks/main.yml`, add a task that applies the
  official Multus thick-plugin manifest from the
  `k8snetworkplumbingwg/multus-cni` repository.
- This DaemonSet installs the Multus binary on every GKE Ubuntu node and rewrites
  the CNI config to chain Multus → the existing GKE CNI.
- Add a wait task to confirm all Multus DaemonSet pods are Running before proceeding.

**Files changed:**
- `ansible/roles/gke_provision/tasks/main.yml` — add Multus DaemonSet apply + wait

---

## Step 2 — Create macvlan Network Attachment Definitions

**New file:** `helm/5g-core/templates/network-attachment-definitions.yaml`

Two NADs are created in the `5g-core` namespace:

| NAD | Purpose | Subnet |
|---|---|---|
| `n3network` | N3 user-plane — UPF GTP-U endpoint reachable by gNB (CU) | `10.10.3.0/24` |
| `n4network` | N4 control-plane — UPF PFCP endpoint reachable by SMF | `10.10.4.0/24` |

Both use `type: macvlan` on the node's primary interface.

**New values added to `helm/5g-core/values.yaml`:**

```yaml
multus:
  enabled: true
  masterInterface: "eth0"   # node's primary NIC on GKE Ubuntu nodes
  n3network:
    subnet:     "10.10.3.0/24"
    rangeStart: "10.10.3.1"
    rangeEnd:   "10.10.3.254"
  n4network:
    subnet:     "10.10.4.0/24"
    rangeStart: "10.10.4.1"
    rangeEnd:   "10.10.4.254"
```

---

## Step 3 — Multi-Slice: values.yaml & config templates

Replace the flat `nssai:` and `ue:` blocks with a `slices:` list. This is the
structural change that drives Steps 4–9.

**Changes to `helm/5g-core/values.yaml`:**

Replace:
```yaml
nssai:
  sst: "1"
ue:
  subnet4: "10.45.0.0/16"
  subnet6: "2001:db8:cafe::/48"
```

With:
```yaml
slices:
  - index: 1
    sst: 1
    sd: "000001"
    smfName: smf1
    upfName: upf1
    subnet4:  "10.45.0.0/16"
    subnet6:  "2001:db8:cafe::/48"
    upfN3Ip:  "10.10.3.11"    # macvlan secondary NIC IP — assigned by NAD static IPAM
    upfN4Ip:  "10.10.4.11"    # macvlan secondary NIC IP — assigned by NAD static IPAM
  - index: 2
    sst: 2
    sd: "000002"
    smfName: smf2
    upfName: upf2
    subnet4:  "10.46.0.0/16"
    subnet6:  "2001:db8:cafe:1::/48"
    upfN3Ip:  "10.10.3.12"
    upfN4Ip:  "10.10.4.12"
```

Remove the old flat `nf.smf` and `nf.upf` enable flags (replaced by the `slices:` list).
All other `nf.*` flags (nrf, scp, amf, etc.) remain unchanged.

---

## Step 4 — Multi-Slice: deployment-smf.yaml

Replace the single Deployment+Service with a `range` loop over `.Values.slices`.

**Changes:**
- Each iteration produces one Deployment (`smf1`, `smf2`) and one Service
- Each SMF Deployment's `env:` section includes per-slice vars that are no longer
  in `commonEnv` (see Step 9):
  - `SMF_SUBNET4`, `SMF_SUBNET6` — differ per slice
  - `UPF_IP` — the per-slice UPF Service name (`upf1`, `upf2`)
  - `SMF_INDEX` — slice index (`1`, `2`) used in the config filename

**Config filename:** the entrypoint selects `smf1.yaml` or `smf2.yaml` based on
`SMF_INDEX`, which maps to the per-slice config keys in the ConfigMap.

---

## Step 5 — Multi-Slice: deployment-upf.yaml

Replace the single Deployment+Service with a `range` loop over `.Values.slices`.

**Key changes vs. current UPF:**

1. **Remove `hostNetwork: true`** — replaced by Multus secondary NICs.

2. **Add Multus pod annotation** to request secondary interfaces:
   ```yaml
   annotations:
     k8s.v1.cni.cncf.io/networks: n3network, n4network
   ```

3. **Static macvlan IPs** — the NAD IPAM uses `type: static`, and each UPF pod
   is annotated with its specific IP for each network:
   ```yaml
   k8s.v1.cni.cncf.io/networks: |
     [
       {"name": "n3network", "ips": ["10.10.3.11/24"]},
       {"name": "n4network", "ips": ["10.10.4.11/24"]}
     ]
   ```
   These IPs come from `slice.upfN3Ip` and `slice.upfN4Ip` in values.yaml, making
   them predictable and embed-able directly into the UPF YAML config.

4. **UPF config bind addresses** point to the macvlan IPs (`net2` / `net3` as named
   by Multus), not `0.0.0.0`.

---

## Step 6 — AMF config: advertise both slices

**File:** `configmap-nf-configs.yaml` — `amf.yaml` section.

Current (hardcoded):
```yaml
plmn_support:
  - plmn_id: ...
    s_nssai:
      - sst: 1
```

Replace with a `range` over `.Values.slices`:
```yaml
plmn_support:
  - plmn_id:
      mcc: ${MCC}
      mnc: ${MNC}
    s_nssai:
      # one entry per slice, rendered by Helm
      - sst: 1
        sd: "000001"
      - sst: 2
        sd: "000002"
```

Since these configs are rendered by Helm (not envsubst), the slice list can be
unrolled directly at chart render time.

---

## Step 7 — NSSF config: register both slices

**File:** `configmap-nf-configs.yaml` — `nssf.yaml` section.

Current (single slice):
```yaml
client:
  nsi:
    - uri: http://nrf:${NRF_SBI_PORT}
      s_nssai:
        sst: 1
```

Replace with a `range` over `.Values.slices` to produce one `nsi` entry per slice.

---

## Step 8 — MongoDB subscriber seed: add slice 2 subscriber

**File:** `configmap-mongodb-init.yaml` — `init-data.js` section.

Add a second subscriber entry:
- `imsi: "001010000000002"`
- Same `k` and `opc` credentials (different IMSI is sufficient for testing)
- `slice: [{ sst: 2, default: true }]`
- APN `internet` (same as slice 1, differentiated by S-NSSAI at the SMF level)

Also add the corresponding `auths` entry for the second IMSI.

---

## Step 9 — _helpers.tpl: remove per-slice vars from commonEnv

**File:** `helm/5g-core/templates/_helpers.tpl`

Remove from `commonEnv`:
- `SMF_SUBNET4`
- `SMF_SUBNET6`
- `UPF_IP`

These are now injected directly in each SMF Deployment's `env:` block (Step 4),
derived from the slice spec in the `range` loop.

All other vars (`MCC`, `MNC`, `TAC`, `NRF_*`, `SCP_*`, `MONGODB_URI`, etc.) remain
in `commonEnv` as they are truly shared across all NFs.

---

## Step 10 — Ansible: masterInterface detection

GKE Ubuntu node primary NIC is usually `eth0` but can vary. Add an optional task or
comment in `ansible/roles/gke_provision/tasks/main.yml` to detect the primary NIC
and pass it as `--set multus.masterInterface=<detected_iface>` during helm install.

**Implementation:** Ansible `k8s_info` on a node object and a `set_fact` that
extracts the default-route NIC name, stored and passed to the helm values override.

**Files changed:**
- `ansible/roles/gke_provision/tasks/main.yml` — optional NIC detection fact
- `ansible/roles/deploy_5g_core/tasks/main.yml` — pass `multus.masterInterface`
  override to `helm upgrade --install`

---

## Files Changed Summary

| File | Type | Change |
|---|---|---|
| `ansible/roles/gke_provision/tasks/main.yml` | Modified | Add Multus DaemonSet apply + wait; optional NIC detection |
| `ansible/roles/deploy_5g_core/tasks/main.yml` | Modified | Pass `multus.masterInterface` to helm values |
| `helm/5g-core/values.yaml` | Modified | Add `multus:` block; replace `nssai:`/`ue:` with `slices:` list; remove `nf.smf`/`nf.upf` flags |
| `helm/5g-core/templates/network-attachment-definitions.yaml` | **New** | macvlan NADs for `n3network` and `n4network` |
| `helm/5g-core/templates/configmap-nf-configs.yaml` | Modified | SMF+UPF configs become `range`-generated per slice; AMF+NSSF advertise all slices |
| `helm/5g-core/templates/configmap-mongodb-init.yaml` | Modified | Add second subscriber + auth entry for slice 2 |
| `helm/5g-core/templates/deployment-smf.yaml` | Modified | `range` over slices; per-slice env vars (`SMF_SUBNET4`, `UPF_IP`) |
| `helm/5g-core/templates/deployment-upf.yaml` | Modified | `range` over slices; remove `hostNetwork:true`; add Multus annotation with static IPs |
| `helm/5g-core/templates/_helpers.tpl` | Modified | Remove per-slice vars from `commonEnv` |

**No changes needed to:** `deployment-amf.yaml`, `deployment-nrf.yaml`,
`deployment-sbi-nfs.yaml`, `deployment-scp.yaml`, `deployment-sepp.yaml`,
`deployment-webui.yaml`, `statefulset-mongodb.yaml`, `daemonset-sctp-init.yaml`,
`terraform/`, `helm/ran/`, `helm/near-rt-ric/`.

---

## Open Questions / Risks

1. **macvlan on GKE — bridge vs passthru mode:** GKE nodes likely have IP forwarding
   and reverse-path filtering that may conflict with macvlan in `bridge` mode. May
   need `mode: passthru` or a DaemonSet that sets `rp_filter=0` on each node. This
   is a known GKE quirk that must be validated during testing.

2. **Static IPs in macvlan IPAM:** Using `type: static` IPAM in the NAD with
   fixed per-pod IPs is reliable and deterministic. The IPs survive pod restarts
   and rescheduling since macvlan IPs are virtual (not node-scoped). Trade-off:
   IP assignments must be kept consistent between `values.yaml` and the NAD IPAM
   range to avoid conflicts.

3. **SMF N4 binding:** In this plan, SMF uses its pod IP for N4 PFCP (simpler —
   SMF-to-UPF PFCP is in-cluster, so the pod IP is reachable). The UPF listens
   for PFCP on its `n4network` macvlan IP and the SMF addresses it by that IP.
   If SMF-side N4 isolation is required later, SMF can also be given a Multus
   secondary NIC on `n4network`.

4. **Multus thick vs thin plugin:** The "thick" Multus plugin (runs as a DaemonSet
   with its own daemon process) is used here. It handles CNI delegation more
   robustly than the "thin" version, particularly on GKE where the node CNI config
   can be regenerated after upgrades.

5. **srsRAN CU slice support:** The srsRAN CU config (`configmap-srsran-configs.yaml`)
   currently advertises only `sst: 1` in `tai_slice_support_list`. It will continue
   to serve UEs on slice 1 only. A second UE pod targeting slice 2 can be added
   later as a follow-on task.
