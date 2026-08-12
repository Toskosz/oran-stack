# O-RAN Stack

A Kubernetes-native O-RAN 5G Standalone network. **Infra** (kubeadm, Multus/OVS,
images) is provisioned with Ansible. **Network functions** (Open5GS, Near-RT RIC,
OCUDU CU/DU + srsUE, xApp, monitoring) are deployed and managed with **Nephio**
(Porch + Config Sync) from a dedicated management cluster. See [docs/NEPHIO.md](docs/NEPHIO.md).

The RAN CU/DU is [OCUDU](https://ocudu.org/) (the Linux Foundation successor to srsRAN Project), pinned to the `release_26_04` tag. The UE simulator remains srsUE from srsRAN_4G, connected over ZMQ virtual radio (sidecar in the DU pod).

## Architecture

```
┌─ Management cluster (Porch / Nephio / Config Sync) ─┐
│  PackageVariants → Git (oran-lab deployment repo)   │
└──────────────────────────┬──────────────────────────┘
                           │ Config Sync
┌──────────────────────────▼──────────────────────────┐
│  Workload: kubeadm + Flannel + Multus + OVS-CNI     │
│                                                                      │
│  namespace: 5g-core          namespace: near-rt-ric                  │
│  ┌──────────────────────┐    ┌─────────────────────┐                 │
│  │ Open5GS              │    │ O-RAN SC Near-RT RIC │                │
│  │  NRF  SCP  SEPP      │    │  e2term  e2mgr       │                │
│  │  AMF  SMF  UPF       │◄──►│  rtmgr   submgr      │                │
│  │  AUSF UDM  PCF       │    │  appmgr  a1mediator  │                │
│  │  NSSF BSF  UDR       │    │  dbaas (Redis)       │                │
│  │  MongoDB  WebUI      │    └─────────────────────┘                 │
│  └──────────────────────┘             ▲                              │
│          ▲ N2/NGAP (SCTP)             │ E2AP (SCTP)                  │
│          │  n2br (10.200.1.0/24)      │  e2br (10.200.3.0/24)        │
│  namespace: ran                        │                              │
│  ┌─────────────────────────────────────┘──────────────────────────┐  │
│  │ OCUDU (CU/DU) + srsUE sidecar                                  │  │
│  │  CU ──F1AP (f1cbr 10.200.2.0/24)──► DU ──ZMQ──► UE           │  │
│  └────────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────────┘
```

SCTP traffic (N2/NGAP, F1-C, E2AP) is carried on dedicated OVS secondary interfaces attached via Multus, not over the Flannel overlay. This eliminates the conntrack/VXLAN flapping that caused N2 and E2 association instability.

**OVS bridges and static IPs:**

| Bridge | Network | AMF | CU | DU | e2term |
|--------|---------|-----|----|----|--------|
| n2br | 10.200.1.0/24 | .2 | .3 | — | — |
| f1cbr | 10.200.2.0/24 | — | .2 | .3 | — |
| e2br | 10.200.3.0/24 | — | .2 | .3 | .4 |

**PLMN:** MCC=001 MNC=01  
**Test subscriber:** IMSI 001010000000001  
**WebUI:** `http://<node-ip>:<nodePort>` — admin / 1423

---

## Prerequisites

| Tool | Version | Purpose |
|------|---------|---------|
| Ansible | ≥ 2.15 | Cluster / Nephio bootstrap |
| Docker | ≥ 24 | Building images |
| Helm | ≥ 3.12 | Package render source (`scripts/render-nephio-packages.sh`) |
| kpt | ≥ 1.0.0-beta | Nephio catalog apply (installed by bootstrap) |

Install Ansible Galaxy collections:

```bash
ansible-galaxy collection install -r ansible/requirements.yml
```

---

## Secrets setup

Create the Ansible Vault file with your Docker Hub credentials:

```bash
ansible-vault create ansible/inventories/group_vars/all/vault.yml
```

Paste:

```yaml
vault_dockerhub_password: "your-docker-hub-pat"
```

Save the vault password to `~/.oran_vault_pass` (never commit this file):

```bash
echo "your-vault-password" > ~/.oran_vault_pass
chmod 600 ~/.oran_vault_pass
```

---

## Quick start (Nephio)

Full detail:

- [GCP end-to-end runbook](docs/GCP_RUNBOOK.md) — clean create, deploy, verify, teardown, and rebuild
- [Nephio architecture and bootstrap](docs/NEPHIO.md)

Infra options for the **workload** cluster:

| Option | Inventory | Doc |
|--------|-----------|-----|
| A — GCP (recommended) | `gcp.ini` | below |
| B — BYO / home LAN (cp1 + w1) | `hosts.ini` | [docs/HOME_LAB_DHCP.md](docs/HOME_LAB_DHCP.md) |
| C — Lab server (OpenVPN, single-node) | `lab.ini` | [docs/LAB_SERVER_VPN.md](docs/LAB_SERVER_VPN.md) |

### 1. Workload cluster (infra)

**Option A — GCP:**

```bash
ansible-playbook ansible/playbooks/gcp-vm-create.yml
ansible-playbook ansible/playbooks/provision.yml -i ansible/inventories/gcp.ini
# Inventory loads group_vars + vault (see ansible/ansible.cfg vault_password_file)
ansible-playbook ansible/playbooks/build_images.yml -i ansible/inventories/gcp.ini
```

**Option B — BYO / home LAN:** copy `ansible/inventories/hosts.ini.example` → `hosts.ini`, then:

```bash
ansible-playbook ansible/playbooks/provision.yml -i ansible/inventories/hosts.ini
ansible-playbook ansible/playbooks/build_images.yml -i ansible/inventories/hosts.ini
```

**Option C — Lab server (OpenVPN, single-node):** connect VPN, copy
`ansible/inventories/lab.ini.example` → `lab.ini`, then follow
[docs/LAB_SERVER_VPN.md](docs/LAB_SERVER_VPN.md):

```bash
ansible-playbook ansible/playbooks/provision.yml -i ansible/inventories/lab.ini
ansible-playbook ansible/playbooks/build_images.yml -i ansible/inventories/lab.ini
```

### 2. Management cluster + Nephio

**GCP mgmt VM** (optional): `gcp-vm-create-mgmt.yml` writes `mgmt.ini`.

**BYO mgmt** (e.g. second Ubuntu laptop): copy
`ansible/inventories/mgmt.ini.example` → `mgmt.ini`, set `ansible_host` /
`control_plane_ip` to that host’s LAN IP, and complete SSH prerequisites
(key ownership, `ssh-copy-id`, `ssh-agent` if the key has a passphrase).
Details: [docs/NEPHIO.md](docs/NEPHIO.md#byo-management-host--ssh-and-mgmtini).

```bash
# Skip gcp-vm-create-mgmt.yml when using a BYO host and a hand-edited mgmt.ini.
ansible-playbook ansible/playbooks/gcp-vm-create-mgmt.yml
# --ask-become-pass when the SSH user needs a sudo password (typical BYO).
# Keep ssh-agent loaded if the private key has a passphrase.
ansible-playbook ansible/playbooks/provision-mgmt.yml \
  -i ansible/inventories/mgmt.ini --ask-become-pass

export KUBECONFIG=$(pwd)/kubeconfig-mgmt
# Set GITHUB_TOKEN to a fine-grained or classic PAT (do not commit tokens).
ansible-playbook ansible/playbooks/bootstrap-nephio.yml \
  -e nephio_git_blueprints_url=https://github.com/Toskosz/oran-stack.git \
  -e nephio_git_mgmt_url=https://github.com/Toskosz/oran-mgmt.git \
  -e nephio_git_oran_lab_url=https://github.com/Toskosz/oran-lab.git \
  -e nephio_git_username=Toskosz \
  -e nephio_git_token="$GITHUB_TOKEN"
```

### 3. Workload GitOps

```bash
export KUBECONFIG=$(pwd)/kubeconfig
ansible-playbook ansible/playbooks/workload-gitops.yml \
  -i ansible/inventories/gcp.ini --ask-vault-pass \
  -e nephio_git_oran_lab_url=https://github.com/Toskosz/oran-lab.git \
  -e nephio_git_username=Toskosz \
  -e nephio_git_token="$GITHUB_TOKEN"
```

### 4. Deploy NFs via Porch

```bash
ansible-playbook ansible/playbooks/deploy-nephio-nfs.yml
```

This applies PackageVariants, publishes revisions in dependency order, waits for
Config Sync and verification jobs, and automatically repairs the stale
Published-history/empty-workload case after a cluster rebuild. It is safe to rerun.
The `xapp-lifecycle` gate restores the legacy AppMgr/RTMgr synchronization,
xApp resubscription, subscription-route preservation, and KPM indication check.
It reruns on every deployment to heal stale runtime routes.
Package order includes **srsUE** inside `ran` (not a separate CNF). Details:
[docs/NEPHIO.md](docs/NEPHIO.md#4-deploy-packages).

Re-render blueprints after Helm chart edits:

```bash
./scripts/render-nephio-packages.sh
./scripts/render-nephio-packages.sh --check
```

### Legacy Helm deploy (deprecated)

`ansible/playbooks/deploy.yml` still runs the old Ansible→Helm path but prints a
deprecation warning. Prefer Nephio; do not mix ownership of the same objects.

---

## Verify

```bash
export KUBECONFIG=$(pwd)/kubeconfig

kubectl get pods -A
kubectl get jobs -n oran-verify

# UE sidecar in the DU pod
kubectl logs -n ran deployment/ocudu-du -c srsue -f
# Look for: RRC Connected  ->  PDU Session Established

# Optional Ansible gates (Nephio migration fallback)
ansible-playbook ansible/playbooks/verify-only.yml
```

---

## Teardown

```bash
# Workload: reset kubeadm (+ optional Helm leftovers), then delete GCP VMs
ansible-playbook ansible/playbooks/teardown.yml \
  -i ansible/inventories/gcp.ini --ask-vault-pass
ansible-playbook ansible/playbooks/gcp-vm-delete.yml \
  -e gcp_zone=us-east1-b   # same zone used at create time

# Management: reset kubeadm, then delete the GCP mgmt VM
ansible-playbook ansible/playbooks/teardown-mgmt.yml \
  -i ansible/inventories/mgmt.ini
ansible-playbook ansible/playbooks/gcp-vm-delete-mgmt.yml \
  -e gcp_zone=us-east1-b
```

---

## GCP configuration reference

| Variable | Default | Description |
|----------|---------|-------------|
| `gcp_project` | `""` | GCP project (resolved from gcloud config if empty) |
| `gcp_zone` | `us-central1-a` | Zone for both VMs |
| `gcp_cp_name` | `oran-cp1` | Control-plane VM name |
| `gcp_w_name` | `oran-w1` | Worker VM name |
| `gcp_cp_machine_type` | `e2-standard-2` | cp1 (2 vCPU / 8 GB) |
| `gcp_w_machine_type` | `e2-standard-4` | w1 (4 vCPU / 16 GB) |
| `gcp_disk_size_gb` | `50` | Boot disk size (GB) |
| `gcp_disk_type` | `pd-ssd` | Boot disk type |
| `gcp_ssh_user` | `oran` | SSH user |
| `gcp_ssh_pub_key_file` | `~/.ssh/oran_gcp.pub` | Public key injected into VMs |
| `gcp_ssh_priv_key_file` | `~/.ssh/oran_gcp` | Private key used by Ansible |

---

## Configuration reference

### Cluster / networking — `ansible/inventories/group_vars/all/vars.yml`

| Variable | Default | Description |
|----------|---------|-------------|
| `kubernetes_version` | `1.30` | K8s apt channel |
| `pod_cidr` | `10.244.0.0/16` | Flannel pod network |
| `service_cidr` | `10.96.0.0/12` | K8s service network |
| `flannel_manifest_url` | flannel v0.25.4 | Flannel DaemonSet manifest |
| `cnao_version` | `0.101.0-rc-0` | Cluster Network Addons Operator |
| `secondary_networks.n2.amf_ip` | `10.200.1.2` | AMF static IP on n2br |
| `secondary_networks.n2.cu_ip` | `10.200.1.3` | CU static IP on n2br |
| `secondary_networks.f1c.cu_ip` | `10.200.2.2` | CU static IP on f1cbr |
| `secondary_networks.f1c.du_ip` | `10.200.2.3` | DU static IP on f1cbr |
| `secondary_networks.e2.cu_ip` | `10.200.3.2` | CU static IP on e2br |
| `secondary_networks.e2.du_ip` | `10.200.3.3` | DU static IP on e2br |
| `secondary_networks.e2.e2term_ip` | `10.200.3.4` | e2term static IP on e2br |

### 5G settings

| Setting | Value | File |
|---------|-------|------|
| MCC / MNC / TAC | 001 / 01 / 1 | `helm/5g-core/values.yaml` |
| MongoDB storage | 20 Gi (`local-path`) | `helm/5g-core/values.yaml` |
| UE subnet | 10.45.0.0/16 | `helm/5g-core/values.yaml` |
| DL ARFCN | 368500 (Band 3, 20 MHz) | `helm/ran/values.yaml` |

---

## Repository structure

```
oran-stack/
├── packages/
│   ├── blueprints/                # kpt packages (Helm-rendered + hand-maintained)
│   ├── values/lab-defaults.yaml   # Render defaults (images, Multus IPs, UE, e2NodeId)
│   ├── variants/                  # PackageVariant examples for oran-lab
│   └── examples/
├── scripts/render-nephio-packages.sh
├── docs/NEPHIO.md                 # Split-cluster Nephio guide
├── docs/LAB_SERVER_VPN.md         # OpenVPN single-node lab path
├── helm/                          # Chart sources (generator of truth for packages)
├── ansible/
│   ├── playbooks/
│   │   ├── provision.yml          # Workload kubeadm + Multus/OVS
│   │   ├── provision-mgmt.yml     # Management kubeadm (no Multus)
│   │   ├── bootstrap-nephio.yml   # Porch + controllers + repo register
│   │   ├── workload-gitops.yml    # Config Sync + RootSync + pull secrets
│   │   ├── deploy-nephio-nfs.yml  # Ordered Porch publish + workload gates
│   │   ├── verify-only.yml        # E2/xApp/UE gates without Helm deploy
│   │   ├── deploy.yml             # DEPRECATED legacy Helm path
│   │   ├── build_images.yml
│   │   ├── teardown.yml
│   │   ├── teardown-mgmt.yml
│   │   ├── gcp-vm-create.yml
│   │   ├── gcp-vm-delete.yml
│   │   ├── gcp-vm-create-mgmt.yml
│   │   └── gcp-vm-delete-mgmt.yml
│   └── roles/
│       ├── nephio_bootstrap/
│       ├── workload_gitops/
│       └── … (kubeadm, ovs, deploy_*, verify_stack, …)
└── …
```

---

## Troubleshooting

**Nodes not Ready after provision**  
Check Flannel pods: `kubectl get pods -n kube-flannel`. Re-run `provision.yml` — all tasks are idempotent.

**Images fail to pull**  
Verify the imagePullSecret: `kubectl get secret dockerhub-secret -n 5g-core`. Re-run `workload-gitops.yml` (or legacy `deploy.yml`) to recreate it.

**UPF pod CrashLoops**  
UPF uses `hostNetwork: true` and creates TUN interfaces. Confirm `net.ipv4.ip_forward=1` is set on the worker: `ssh <node> sysctl net.ipv4.ip_forward`. The `kubeadm_prereqs` role sets this.

**SCTP associations not establishing**  
Confirm secondary interfaces are attached: `kubectl exec -n ran deploy/ocudu-cu -- ip addr`. You should see interfaces with IPs from the 10.200.x.0/24 ranges. Check OVS bridge and VXLAN tunnels: `sudo ovs-vsctl show` on each node.

**E2 interface not connecting**  
Check `kubectl logs -n ran deployment/ocudu-du` for the E2 Setup Request and `kubectl logs -n near-rt-ric deployment/ric-e2term` for the response. The DU intentionally waits 30 seconds after F1 Setup before sending E2 Setup.

**MongoDB PVC stays Pending**  
Verify local-path-provisioner is running: `kubectl get pods -n local-path-storage`. If missing, re-run `provision.yml`.
