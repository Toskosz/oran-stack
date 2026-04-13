# O-RAN Stack

A local O-RAN 5G Standalone network deployed on a kubeadm Kubernetes cluster provisioned with Vagrant and Ansible.

## Architecture

```
┌──────────────────────────────────────────────────────┐
│  Kubernetes cluster (kubeadm + Calico)               │
│                                                      │
│  namespace: 5g-core          namespace: near-rt-ric  │
│  ┌──────────────────────┐    ┌─────────────────────┐ │
│  │ Open5GS              │    │ O-RAN SC Near-RT RIC │ │
│  │  NRF  SCP  SEPP      │    │  e2term  e2mgr       │ │
│  │  AMF  SMF  UPF       │◄──►│  rtmgr   submgr      │ │
│  │  AUSF UDM  PCF       │    │  appmgr  a1mediator  │ │
│  │  NSSF BSF  UDR       │    │  dbaas (Redis)       │ │
│  │  MongoDB  WebUI      │    └─────────────────────┘ │
│  └──────────────────────┘             ▲              │
│             ▲ N2/NGAP (SCTP)          │ E2 (SCTP)    │
│             │                         │              │
│  namespace: ran                        │              │
│  ┌──────────────────────────────────┐  │              │
│  │ srsRAN Project                   │──┘              │
│  │  CU ──F1AP──► DU ──ZMQ──► UE    │                 │
│  └──────────────────────────────────┘                 │
└──────────────────────────────────────────────────────┘

VM layout (Vagrant, VirtualBox):
  cp1  192.168.56.10  — control-plane (2 vCPU / 4 GB default)
  w1   192.168.56.11  — worker        (4 vCPU / 6 GB default)
```

**PLMN:** MCC=001 MNC=01  
**Test subscriber:** IMSI 001010000000001  
**WebUI:** `http://192.168.56.10:<nodePort>` — admin / 1423

---

## Prerequisites

| Tool | Version | Purpose |
|------|---------|---------|
| VirtualBox | ≥ 7.0 | VM hypervisor |
| Vagrant | ≥ 2.3 | VM lifecycle |
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

### 1. Start VMs

```bash
vagrant up
```

Default sizing is 2 vCPU/4 GB (cp1) + 4 vCPU/6 GB (w1) — fits on a 16 GB host.  
For a cloud VM with more RAM, override via environment variables:

```bash
CP_CPUS=4 CP_MEMORY=8192 W_CPUS=4 W_MEMORY=16384 vagrant up
```

### 2. Provision the Kubernetes cluster

```bash
ansible-playbook ansible/playbooks/provision.yml
```

Installs containerd, kubeadm, Calico CNI, and the local-path-provisioner on both nodes, then writes `./kubeconfig` to the repo root.

Verify:

```bash
export KUBECONFIG=$(pwd)/kubeconfig
kubectl get nodes
# NAME   STATUS   ROLES           AGE   VERSION
# cp1    Ready    control-plane   ...   v1.30.x
# w1     Ready    <none>          ...   v1.30.x
```

### 3. Build and push Docker images

Only needed if images are not already on Docker Hub, or after source changes:

```bash
ansible-playbook ansible/playbooks/build_images.yml --ask-vault-pass
```

Builds four images (`oran-5gcore`, `oran-webui`, `oran-srsran`, `oran-srsue`) and pushes them to `x0tok/` on Docker Hub.

### 4. Deploy the stack

```bash
ansible-playbook ansible/playbooks/deploy.yml --ask-vault-pass
```

Deploys in order: **5g-core → near-rt-ric → ran**.  
Each layer waits to be healthy before the next is started.  
At the end the AMF NGAP NodePort, e2term SCTP NodePort, and WebUI NodePort are printed.

### 5. Verify

```bash
# All pods running
kubectl get pods -A

# UE attached to the 5G core
kubectl logs -n ran deployment/srsue -f
# Look for: RRC Connected  ->  PDU Session Established
```

---

## Teardown

```bash
# Remove all Helm releases and reset the kubeadm cluster
ansible-playbook ansible/playbooks/teardown.yml --ask-vault-pass

# Destroy VMs
vagrant destroy -f
```

---

## Running on GCP

If your local machine does not have enough RAM, you can provision two GCP VMs directly as the kubeadm cluster nodes (cp1 + w1). No nested virtualisation. The same Ansible kubeadm roles that run against Vagrant VMs run against these GCP VMs — you just pass a different inventory file.

### Prerequisites

1. `gcloud` CLI installed and ADC configured:
   ```bash
   gcloud auth application-default login
   gcloud config set project YOUR_PROJECT_ID
   ```
2. SSH key pair dedicated to the cluster VMs (generate once):
   ```bash
   ssh-keygen -t rsa -b 4096 -f ~/.ssh/oran_gcp
   ```
3. `google.cloud` Ansible collection installed (included in `requirements.yml`):
   ```bash
   ansible-galaxy collection install -r ansible/requirements.yml
   ```

### 1. Provision the VMs

```bash
ansible-playbook ansible/playbooks/gcp-vm-create.yml
```

This will:
1. Resolve your active GCP project
2. Enable the Compute Engine API
3. Create two firewall rules (`oran-ssh`, `oran-internal`)
4. Create **cp1** (`e2-standard-2`, 2 vCPU / 8 GB) and **w1** (`e2-standard-4`, 4 vCPU / 16 GB)
5. Wait for SSH on both VMs
6. Write `ansible/inventories/gcp.ini` with the VMs' IPs
7. Print the next steps

Override defaults if needed:

```bash
ansible-playbook ansible/playbooks/gcp-vm-create.yml \
  -e gcp_zone=europe-west1-b \
  -e gcp_cp_machine_type=e2-standard-4 \
  -e gcp_w_machine_type=e2-standard-8
```

### 2. Bootstrap the Kubernetes cluster

```bash
ansible-playbook ansible/playbooks/provision.yml \
  -i ansible/inventories/gcp.ini
```

### 3. Deploy the O-RAN stack

```bash
ansible-playbook ansible/playbooks/deploy.yml \
  -i ansible/inventories/gcp.ini --ask-vault-pass
```

### Teardown

```bash
# Remove Helm releases + reset kubeadm (keep VMs)
ansible-playbook ansible/playbooks/teardown.yml \
  -i ansible/inventories/gcp.ini --ask-vault-pass

# Delete VMs, firewall rules, and gcp.ini
ansible-playbook ansible/playbooks/gcp-vm-delete.yml
```

### GCP configuration reference

| Variable | Default | Description |
|----------|---------|-------------|
| `gcp_project` | `""` | GCP project (resolved from gcloud config if empty) |
| `gcp_zone` | `us-central1-a` | Zone for both VMs |
| `gcp_cp_name` | `oran-cp1` | Control-plane VM name |
| `gcp_w_name` | `oran-w1` | Worker VM name |
| `gcp_cp_machine_type` | `e2-standard-2` | cp1 machine type (2 vCPU / 8 GB) |
| `gcp_w_machine_type` | `e2-standard-4` | w1 machine type (4 vCPU / 16 GB) |
| `gcp_disk_size_gb` | `50` | Boot disk size (GB) |
| `gcp_disk_type` | `pd-ssd` | Boot disk type |
| `gcp_ssh_user` | `oran` | SSH user created on VMs |
| `gcp_ssh_pub_key_file` | `~/.ssh/oran_gcp.pub` | Public key injected into VMs |
| `gcp_ssh_priv_key_file` | `~/.ssh/oran_gcp` | Private key used by Ansible |

Defaults are in `ansible/roles/gcp_vm/defaults/main.yml`.

---

## Configuration reference

### VM sizing — `Vagrantfile`

| Variable | Default | Description |
|----------|---------|-------------|
| `CP_CPUS` | 2 | Control-plane vCPUs |
| `CP_MEMORY` | 4096 | Control-plane RAM (MB) |
| `W_CPUS` | 4 | Worker vCPUs |
| `W_MEMORY` | 6144 | Worker RAM (MB) |

### Cluster settings — `ansible/inventories/group_vars/all/vars.yml`

| Variable | Default | Description |
|----------|---------|-------------|
| `kubernetes_version` | `1.30` | K8s apt channel |
| `pod_cidr` | `10.244.0.0/16` | Calico pod network |
| `service_cidr` | `10.96.0.0/12` | K8s service network |
| `control_plane_ip` | `192.168.56.10` | Advertise address for kubeadm init |
| `calico_version` | `3.28` | Tigera operator version |
| `dockerhub_username` | `x0tok` | Docker Hub org for image pulls |

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
├── Vagrantfile                    # 2-node VM definition (local dev path)
├── entrypoint.sh                  # NF container entrypoint (envsubst + launch)
├── init-mongodb.js                # MongoDB replica-set init
├── init-webui-data.js             # MongoDB subscriber seed data
├── configs/                       # Open5GS NF config templates (baked into image)
├── dockerfiles/                   # Dockerfiles for the 4 custom images
├── helm/
│   ├── 5g-core/                   # Open5GS + MongoDB Helm chart
│   ├── near-rt-ric/               # O-RAN SC Near-RT RIC Helm chart
│   └── ran/                       # srsRAN CU/DU/UE Helm chart
├── ansible/
│   ├── ansible.cfg
│   ├── requirements.yml
│   ├── inventories/
│   │   ├── vagrant.ini            # Vagrant VM inventory (local path)
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
│       ├── kubeadm_prereqs/       # OS prep (swap, modules, containerd, kubeadm)
│       ├── kubeadm_control_plane/ # kubeadm init, Calico, local-path-provisioner
│       ├── kubeadm_worker/        # kubeadm join
│       ├── kubeadm_teardown/      # kubeadm reset + CNI/iptables cleanup
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
Check Calico pods: `kubectl get pods -n calico-system`. If the Tigera operator is stuck, re-run `provision.yml` — all tasks are idempotent.

**Images fail to pull**  
Verify the imagePullSecret: `kubectl get secret dockerhub-secret -n 5g-core`. Re-run `deploy.yml` to recreate it.

**UPF pod CrashLoops**  
UPF uses `hostNetwork: true` and creates TUN interfaces. Confirm `net.ipv4.ip_forward=1` is set on the worker: `ssh vagrant@192.168.56.11 sysctl net.ipv4.ip_forward`. The `kubeadm_prereqs` role sets this.

**E2 interface not connecting**  
Check `kubectl logs -n ran deployment/srs-du` for the E2 Setup Request and `kubectl logs -n near-rt-ric deployment/ric-e2term` for the response. The DU intentionally waits 30 seconds after F1 Setup before sending E2 Setup.

**MongoDB PVC stays Pending**  
Verify local-path-provisioner is running: `kubectl get pods -n local-path-storage`. If missing, re-run `provision.yml`.
