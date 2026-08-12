# Nephio split-cluster management for oran-stack

Nephio (Porch + Controllers + Config Sync) deploys and manages the O-RAN lab
network functions. Ansible retains **infra only**: VMs, kubeadm, Multus/OVS,
image builds, and teardown.

## Topology

| Cluster | Role | Kubeconfig |
|---------|------|------------|
| **Management** | Porch, Nephio controllers, Config Sync (mgmt), WebUI | `./kubeconfig-mgmt` |
| **Workload (oran-lab)** | Existing O-RAN kubeadm lab (Flannel + Multus + OVS) | `./kubeconfig` |

```
Management ──Porch──► Git (blueprints, mgmt, oran-lab)
Workload   ◄─Config Sync── oran-lab deployment repo
```

## Package map

| Package | Contents |
|---------|----------|
| `ns-and-secrets` | Namespaces (`5g-core`, `near-rt-ric`, `ran`, `ricxapp`, `monitoring`, `oran-verify`) |
| `5g-core` | Open5GS NFs + MongoDB + WebUI (from Helm) |
| `mongodb-init` | Job: replica set + subscriber seed (IMSI `001010000000001`) |
| `near-rt-ric` | O-RAN SC Near-RT RIC platform |
| `ran` | **OCUDU CU + DU + srsUE sidecar** (ZMQ on localhost) |
| `verify-e2` | Job gate: e2mgr gNB registration |
| `xapp-simple-mon` | KPM simple-mon xApp |
| `xapp-lifecycle` | Job: AppMgr registration, RTMgr resync, xApp resubscribe, route preservation, and KPM indication gate |
| `verify-ue` | Job gate: RRC Connected + PDU Session |
| `monitoring` | Prometheus + Grafana |

**srsUE** is not a separate package — it is part of `ran` (`deployUE: true`).

### Deploy order

`ns-and-secrets` → `5g-core` → `mongodb-init` → `near-rt-ric` → `ran` → `verify-e2` → `xapp-simple-mon` → `xapp-lifecycle` → `verify-ue` → `monitoring`

Example PackageVariants: [`packages/variants/oran-lab-packagevariants.yaml`](../packages/variants/oran-lab-packagevariants.yaml).

### Re-rendering from Helm

```bash
./scripts/render-nephio-packages.sh
# optional custom values:
./scripts/render-nephio-packages.sh --values packages/values/lab-defaults.yaml
```

Lab defaults (images, Multus IPs, PLMN, UE credentials, `e2NodeId`) live in
[`packages/values/lab-defaults.yaml`](../packages/values/lab-defaults.yaml).

### Setters / overlays

Mutate via PackageVariant pipelines (`apply-setters`) or by editing
`lab-defaults.yaml` and re-rendering. Common knobs:

| Setter / value | Purpose |
|----------------|---------|
| `images.*.repository` / `tag` | Custom images |
| `secondaryNetworks.*.*IP` | Multus static IPs (must match provision NADs) |
| `ue.imsi` / `k` / `opc` | UE credentials (must match MongoDB seed) |
| `deployUE` | Enable/disable srsUE sidecar |
| `xapp.e2NodeId` | Must match e2mgr `ranName` |
| `plmn.*` | MCC/MNC/TAC |

**Out of scope for packages:** NetworkAttachmentDefinitions and OVS bridges —
created by `provision.yml` on the workload cluster.

For a single copy-paste GCP procedure covering prerequisites, create, deploy,
verification, complete teardown, and rebuild, see
[GCP_RUNBOOK.md](GCP_RUNBOOK.md).

## Bootstrap procedure

### 1. Management cluster (infra)

Prefer a dedicated host for Porch/Nephio (~4 vCPU / 8 GB+). Options:

| Option | How |
|--------|-----|
| GCP VM | `gcp-vm-create-mgmt.yml` (writes `mgmt.ini`) |
| BYO (e.g. second Ubuntu laptop) | Copy/edit `mgmt.ini` yourself — steps below |

Do **not** co-locate management kubeadm with the workload cluster on the same
host OS. The Ansible controller (often WSL2) is separate from both.

#### BYO management host — SSH and `mgmt.ini`

On the **controller** (Ansible laptop / WSL2):

1. **SSH key usable by your user** (not root-owned):

   ```bash
   sudo chown "$USER:$USER" ~/.ssh/id_ed25519 ~/.ssh/id_ed25519.pub
   chmod 600 ~/.ssh/id_ed25519
   chmod 644 ~/.ssh/id_ed25519.pub
   ```

2. **Install the public key** on the management host (password login once):

   ```bash
   ssh-copy-id -i ~/.ssh/id_ed25519.pub <user>@<mgmt_lan_ip>
   ```

3. **If the private key has a passphrase**, unlock it for this shell (Ansible
   and `BatchMode` SSH will not prompt):

   ```bash
   eval "$(ssh-agent -s)"
   ssh-add ~/.ssh/id_ed25519
   ```

4. **Verify key-only SSH** (must print the hostname with no password prompt):

   ```bash
   ssh -i ~/.ssh/id_ed25519 -o BatchMode=yes <user>@<mgmt_lan_ip> 'hostname'
   ```

5. **Inventory** — `ansible_host` is the **management host** IP (reachable
   from the controller), not the controller’s own IP:

   ```bash
   cp ansible/inventories/mgmt.ini.example ansible/inventories/mgmt.ini
   ```

   Example (`mgmt.ini` is gitignored):

   ```ini
   [control_plane]
   mgmt1  ansible_host=192.168.15.86  control_plane_ip=192.168.15.86  ansible_user=tokarski

   [workers]

   [k8s_cluster:children]
   control_plane
   workers

   [k8s_cluster:vars]
   ansible_ssh_private_key_file=~/.ssh/id_ed25519
   ansible_python_interpreter=auto_legacy_silent
   nephio_mgmt_mode=true

   [local]
   localhost ansible_connection=local
   ```

   | Field | Value |
   |-------|--------|
   | `ansible_host` | IP the controller uses for SSH / later `kubectl` |
   | `control_plane_ip` | Same address **on that host** (`ip -4 addr`); kubeadm requires it |
   | `ansible_user` | SSH login on the management host |
   | `ansible_ssh_private_key_file` | Private key on the controller |
   | `[workers]` | Leave empty for single-node mgmt |

   Prefer a reserved/static DHCP lease so the IP does not change.

6. **Remote user must have `sudo`** (password OK — see `--ask-become-pass`).

#### Provision management kubeadm

```bash
# Optional GCP VM for management (~4 vCPU / 8 GB+)
ansible-playbook ansible/playbooks/gcp-vm-create-mgmt.yml

# kubeadm without Multus/OVS (writes ./kubeconfig-mgmt)
# Use --ask-become-pass when the SSH user has a sudo password (typical BYO/laptop).
# GCP VMs with passwordless sudo can omit it.
# Keep ssh-agent loaded in this shell if the key has a passphrase.
ansible-playbook ansible/playbooks/provision-mgmt.yml \
  -i ansible/inventories/mgmt.ini --ask-become-pass
```

### 2. Nephio on management

```bash
export KUBECONFIG=$(pwd)/kubeconfig-mgmt
# Set GITHUB_TOKEN to a fine-grained or classic PAT (do not commit tokens).
ansible-playbook ansible/playbooks/bootstrap-nephio.yml \
  -e nephio_git_blueprints_url=https://github.com/Toskosz/oran-stack.git \
  -e nephio_git_mgmt_url=https://github.com/Toskosz/oran-mgmt.git \
  -e nephio_git_oran_lab_url=https://github.com/Toskosz/oran-lab.git \
  -e nephio_git_username=Toskosz \
  -e nephio_git_token="$GITHUB_TOKEN"
```

This installs Porch, Nephio controllers, Config Sync (mgmt), optional WebUI
from the Nephio catalog (`v5.0.0` by default), and registers Git repos with
`porchctl`. Catalog `kpt live apply` retries (default 5× / 30s) so Config Sync
operator startup races do not require a manual re-run.

Run the playbook from `ansible/` (so `ansible.cfg` resolves roles), or set
`ANSIBLE_CONFIG=ansible/ansible.cfg` from the repo root.

Create empty Git repos first:

- **blueprints** — this repository (or a fork); Porch reads `packages/blueprints`
- **mgmt** — management-cluster deployment repo
- **oran-lab** — workload deployment repo (`--deployment=true`)

If blueprints live in a monorepo subdirectory, register with the path Porch
expects for your provider, or push `packages/blueprints/*` to a dedicated
blueprints remote.

### 3. Workload cluster GitOps

After normal workload provision (`provision.yml` + Multus/OVS + `build_images.yml`):

```bash
export KUBECONFIG=$(pwd)/kubeconfig   # workload
ansible-playbook ansible/playbooks/workload-gitops.yml \
  -i ansible/inventories/gcp.ini --ask-vault-pass \
  -e nephio_git_oran_lab_url=https://github.com/Toskosz/oran-lab.git \
  -e nephio_git_username=Toskosz \
  -e nephio_git_token="$GITHUB_TOKEN"
```

Use the same inventory as `provision.yml` (`gcp.ini`, `lab.ini`, or `hosts.ini`) so `group_vars` and the Docker Hub vault load.

Installs Config Sync, RootSync → `oran-lab`, workload CRDs, and Docker Hub
imagePullSecrets in NF namespaces (from Ansible Vault).

**Do not run `deploy.yml`** — NFs arrive only via Config Sync.

### 4. Deploy packages

Run the automated deployment after both clusters and workload GitOps are ready:

```bash
ansible-playbook ansible/playbooks/deploy-nephio-nfs.yml
```

The playbook applies PackageVariants, proposes and approves revisions in dependency
order, and waits for each workload gate:

`ns-and-secrets` → `5g-core` → `mongodb-init` → `near-rt-ric` → `ran` →
`verify-e2` → `xapp-simple-mon` → `xapp-lifecycle` → `verify-ue` → `monitoring`

The E2 Job proves that the gNB is registered in e2mgr. `xapp-lifecycle` then
matches the legacy Helm deployment behavior: it waits for AppMgr registration,
resynchronizes RTMgr, restarts the xApp against stable routes, verifies the
subscription routes, preserves them while waiting, and requires
`RIC Indication Received` before UE verification starts. A normal rerun
recreates this Job so broken runtime routes are healed even when package
revisions are unchanged.

Nephio NF configuration is sourced from `packages/values/lab-defaults.yaml`.
Running `scripts/render-nephio-packages.sh` also generates the shared
`oran-lab-settings` ConfigMaps consumed by MongoDB and verification Jobs.
Inventory-only NF value changes do not update GitOps manifests. Use
`scripts/render-nephio-packages.sh --check` to detect rendered or
legacy/Nephio configuration drift.

Runtime gate settings can be overridden with Ansible extra vars:

```bash
ansible-playbook ansible/playbooks/deploy-nephio-nfs.yml \
  -e deploy_e2_recovery_enabled=true \
  -e deploy_ue_attach_required=true \
  -e deploy_xapp_indication_retries=18
```

It is safe to rerun. Packages already present on a healthy workload are skipped.
If a rebuilt workload is empty while Porch only sees old Published history, the
playbook automatically publishes fresh revisions from the PackageVariant upstreams
and then restores PackageVariant reconciliation. It retains Git history and does not
delete or reset the `oran-lab` repository.

```bash
# Explicitly publish fresh revisions of every package:
ansible-playbook ansible/playbooks/deploy-nephio-nfs.yml \
  -e deploy_force_fresh=true
```

The underlying script can also be run directly:

```bash
./packages/examples/deploy-oran-lab.sh
```

Manual lifecycle commands remain available for review-driven environments:

```bash
export KUBECONFIG=$(pwd)/kubeconfig-mgmt
kubectl get packagerevisions | grep -E 'oran-lab.*(Draft|Proposed)'
porchctl rpkg propose <revision-name> -n default
porchctl rpkg approve <revision-name> -n default
```

### 5. Verify

```bash
export KUBECONFIG=$(pwd)/kubeconfig
kubectl get pods -A
kubectl get jobs -n oran-verify
kubectl logs -n ran deployment/ocudu-du -c srsue --tail=50
# Expect: RRC Connected → PDU Session Established
```

Fallback (migration): `ansible-playbook ansible/playbooks/verify-only.yml`.

## Ansible: keep vs retire

| Keep | Retire (legacy Helm path) |
|------|---------------------------|
| `gcp-vm-*`, `provision.yml`, `build_images.yml`, `deploy-nephio-nfs.yml`, `teardown.yml`, `teardown-mgmt.yml` | `deploy.yml` + `deploy_*` roles (deprecated) |
| `provision-mgmt.yml`, `bootstrap-nephio.yml`, `workload-gitops.yml` | Helm `--set` wiring in deploy roles |
| Vault for Docker Hub pull secrets | README Helm-first quick start |

### Teardown (management)

```bash
ansible-playbook ansible/playbooks/teardown-mgmt.yml \
  -i ansible/inventories/mgmt.ini
# GCP only — omit for BYO hosts you want to keep:
ansible-playbook ansible/playbooks/gcp-vm-delete-mgmt.yml \
  -e gcp_zone=us-east1-b
```

Cluster teardown deliberately retains the external `oran-lab`, `oran-mgmt`, and
blueprint Git repositories. This preserves audit history. The next
`deploy-nephio-nfs.yml` run detects an empty/stale deployment branch and republishes
fresh package revisions automatically; deleting Git repositories is not part of a
normal clean rebuild.

## Catalog pin

Bootstrap defaults pin Nephio catalog `@v5.0.0` (matched Porch image tags).
`origin/main` can pair Deployment args with a mismatched `porch-server:latest`.
Override with `-e nephio_catalog_ref=...` if needed. After changing the pin,
delete `.nephio-bootstrap/` so `kpt pkg get` re-fetches packages.

## References

- [Nephio multi-VM install](https://docs.nephio.org/docs/guides/install-guides/install-on-multiple-vm/)
- [Nephio common components](https://docs.nephio.org/docs/guides/install-guides/common-components/)
