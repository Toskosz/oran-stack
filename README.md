# O-RAN Stack

A Kubernetes-native O-RAN 5G Standalone network running on a kubeadm cluster provisioned with Ansible.

The RAN CU/DU is [OCUDU](https://ocudu.org/) (the Linux Foundation successor to srsRAN Project), pinned to the `release_26_04` tag. The UE simulator remains srsUE from srsRAN_4G, connected over ZMQ virtual radio.

## Architecture

```
┌──────────────────────────────────────────────────────────────────────┐
│  Kubernetes cluster (kubeadm + Flannel + Multus + OVS-CNI)          │
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
│  │ OCUDU (CU/DU) + srsUE                                          │  │
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
| Ansible | ≥ 2.15 | Cluster provisioning and deployment |
| Docker | ≥ 24 | Building images |
| Helm | ≥ 3.12 | Used via Ansible `kubernetes.core` collection |

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

## Quick start

### Option A: GCP VMs (recommended)

#### 1. Provision the VMs

```bash
ansible-playbook ansible/playbooks/gcp-vm-create.yml
```

This creates two GCP VMs (`oran-cp1`, `oran-w1`) and writes `ansible/inventories/gcp.ini`.

#### 2. Bootstrap the cluster

```bash
ansible-playbook ansible/playbooks/provision.yml \
  -i ansible/inventories/gcp.ini
```

Installs containerd, kubeadm, Flannel CNI, Multus, OVS-CNI (via CNAO), OVS VXLAN tunnels between nodes, and local-path-provisioner. Writes `./kubeconfig`.

#### 3. Build and push Docker images

```bash
ansible-playbook ansible/playbooks/build_images.yml --ask-vault-pass
```

#### 4. Deploy the stack

```bash
ansible-playbook ansible/playbooks/deploy.yml \
  -i ansible/inventories/gcp.ini --ask-vault-pass
```

### Option B: Bring Your Own machines

For a two-machine home lab, reserve fixed LAN IPs on your router first so
`ansible_host` does not change after reboot. See
[docs/HOME_LAB_DHCP.md](docs/HOME_LAB_DHCP.md) for a step-by-step guide.

Copy and edit the inventory template:

```bash
cp ansible/inventories/hosts.ini.example ansible/inventories/hosts.ini
# edit hosts.ini with your machine IPs and SSH user
```

Then run:

```bash
ansible-playbook ansible/playbooks/provision.yml \
  -i ansible/inventories/hosts.ini

ansible-playbook ansible/playbooks/deploy.yml \
  -i ansible/inventories/hosts.ini --ask-vault-pass
```

---

## Verify

```bash
export KUBECONFIG=$(pwd)/kubeconfig

# All pods running
kubectl get pods -A

# UE attached to the 5G core
kubectl logs -n ran deployment/srsue -f
# Look for: RRC Connected  ->  PDU Session Established

# OVS bridges on each node
ssh <node> sudo ovs-vsctl show
```

---

## Teardown

```bash
# Remove all Helm releases and reset the kubeadm cluster
ansible-playbook ansible/playbooks/teardown.yml \
  -i ansible/inventories/gcp.ini --ask-vault-pass

# Delete GCP VMs
ansible-playbook ansible/playbooks/gcp-vm-delete.yml
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
├── entrypoint.sh                  # NF container entrypoint (envsubst + launch)
├── init-mongodb.js                # MongoDB replica-set init
├── init-webui-data.js             # MongoDB subscriber seed data
├── configs/                       # Open5GS NF config templates (baked into image)
├── dockerfiles/                   # Dockerfiles for the 4 custom images
├── helm/
│   ├── 5g-core/                   # Open5GS + MongoDB Helm chart
│   ├── near-rt-ric/               # O-RAN SC Near-RT RIC Helm chart
│   └── ran/                       # OCUDU CU/DU + srsUE Helm chart
├── ansible/
│   ├── ansible.cfg
│   ├── requirements.yml
│   ├── inventories/
│   │   ├── hosts.ini.example      # BYO machine inventory template
│   │   ├── gcp.ini                # GCP VM inventory (generated by gcp-vm-create.yml)
│   │   └── group_vars/all/
│   │       ├── vars.yml           # All non-secret variables
│   │       └── vault.yml          # Encrypted secrets (dockerhub_password)
│   ├── playbooks/
│   │   ├── provision.yml          # kubeadm cluster bootstrap
│   │   ├── build_images.yml       # Docker build + push
│   │   ├── deploy.yml             # Helm deploy (core -> ric -> ran)
│   │   ├── teardown.yml           # Helm uninstall + kubeadm reset
│   │   ├── gcp-vm-create.yml      # Provision GCP cluster VMs
│   │   └── gcp-vm-delete.yml      # Delete GCP cluster VMs
│   └── roles/
│       ├── kubeadm_prereqs/       # OS prep (swap, modules, OVS, containerd, kubeadm)
│       ├── kubeadm_control_plane/ # kubeadm init, Flannel, Multus, CNAO, NADs
│       ├── kubeadm_worker/        # kubeadm join
│       ├── kubeadm_teardown/      # kubeadm reset + OVS/iptables cleanup
│       ├── ovs_vxlan/             # OVS bridge + VXLAN tunnel setup between nodes
│       ├── gcp_vm/                # GCP VM create / delete (google.cloud collection)
│       ├── container_images/      # Docker build + push
│       ├── deploy_5g_core/        # Helm deploy for 5g-core
│       ├── deploy_ric/            # Helm deploy for near-rt-ric
│       └── deploy_ran/            # Helm deploy for ran
└── docs/
    ├── STATUS.md
    ├── LEARNINGS.md
    └── E2_STABILIZATION_PLAN.md
```

---

## Troubleshooting

**Nodes not Ready after provision**  
Check Flannel pods: `kubectl get pods -n kube-flannel`. Re-run `provision.yml` — all tasks are idempotent.

**Images fail to pull**  
Verify the imagePullSecret: `kubectl get secret dockerhub-secret -n 5g-core`. Re-run `deploy.yml` to recreate it.

**UPF pod CrashLoops**  
UPF uses `hostNetwork: true` and creates TUN interfaces. Confirm `net.ipv4.ip_forward=1` is set on the worker: `ssh <node> sysctl net.ipv4.ip_forward`. The `kubeadm_prereqs` role sets this.

**SCTP associations not establishing**  
Confirm secondary interfaces are attached: `kubectl exec -n ran deploy/ocudu-cu -- ip addr`. You should see interfaces with IPs from the 10.200.x.0/24 ranges. Check OVS bridge and VXLAN tunnels: `sudo ovs-vsctl show` on each node.

**E2 interface not connecting**  
Check `kubectl logs -n ran deployment/ocudu-du` for the E2 Setup Request and `kubectl logs -n near-rt-ric deployment/ric-e2term` for the response. The DU intentionally waits 30 seconds after F1 Setup before sending E2 Setup.

**MongoDB PVC stays Pending**  
Verify local-path-provisioner is running: `kubectl get pods -n local-path-storage`. If missing, re-run `provision.yml`.
