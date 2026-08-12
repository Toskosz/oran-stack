# Lab server via OpenVPN (single-node workload)

Third infra path for oran-stack: one lab host reachable from your laptop over
**OpenVPN + SSH**. The workload cluster is **single-node kubeadm**;
`provision.yml` untaints the control-plane when `[workers]` is empty so pods
can schedule.

GCP and two-node BYO/home-lab (`hosts.ini`) paths are unchanged.

| Path | Inventory | Topology |
|------|-----------|----------|
| GCP | `gcp.ini` (generated) | cp1 + w1 VMs |
| Home / BYO LAN | `hosts.ini` | cp1 + w1 on LAN |
| **Lab VPN (this doc)** | `lab.ini` | single-node cp1 |

**NFs:** Nephio remains primary. This path provisions **workload** infra only.
Keep Porch / management on an existing mgmt cluster (GCP or BYO `mgmt.ini`).
Typical three-role lab: **controller** (WSL2/Ansible) + **mgmt host** (Ubuntu
laptop / GCP) + **lab server** (this doc’s `lab.ini`). Full BYO mgmt steps
(SSH key ownership, `ssh-copy-id`, passphrase/`ssh-agent`, filling `mgmt.ini`,
`--ask-become-pass`): [NEPHIO.md — BYO management host](NEPHIO.md#byo-management-host--ssh-and-mgmtini).
For a closed lab without a second cluster, the deprecated `deploy.yml` Helm path
still works (do not mix with Nephio ownership of the same objects).

---

## Prerequisites

| Requirement | Notes |
|-------------|--------|
| OpenVPN client | Connected before Ansible / `kubectl` |
| SSH key auth (lab) | Key auth to the lab server; same key as in `lab.ini` |
| Management cluster | Separate host via `mgmt.ini` — see [NEPHIO.md](NEPHIO.md#byo-management-host--ssh-and-mgmtini) |
| Ansible ≥ 2.15 on the laptop | Galaxy collections: `ansible-galaxy collection install -r ansible/requirements.yml` |
| Lab host resources | Prefer ≥ 4 vCPU / 16 GB RAM / 50 GB disk for the full O-RAN stack on one box |
| Passphrase-protected SSH key | `eval "$(ssh-agent -s)"` + `ssh-add` before Ansible in that shell |

Do **not** run a second kubeadm node on the same host OS (port conflicts on
6443, kubelet, etcd, containerd). Nested VMs are out of scope for this path.

---

## 1. Connectivity check

Bring the VPN up, then confirm reachability to the lab OpenVPN IP:

```bash
ping -c 2 <vpn_ip>
ssh -i ~/.ssh/id_ed25519 ubuntu@<vpn_ip> 'hostname; ip -4 addr'
```

Note the address you use for SSH — that is `ansible_host` / `control_plane_ip`
in the inventory. Prefer the VPN-reachable address, not a public or
lab-LAN-only address your laptop cannot use while on VPN.

---

## 2. Inventory

```bash
cp ansible/inventories/lab.ini.example ansible/inventories/lab.ini
# edit ansible/inventories/lab.ini
```

Set:

- `ansible_host` and `control_plane_ip` to the VPN IP (same value when that IP
  is the node’s primary address)
- `ansible_user` and `ansible_ssh_private_key_file`
- Leave `[workers]` empty

`lab.ini` is gitignored.

---

## 3. Provision workload + images

```bash
ansible-playbook ansible/playbooks/provision.yml -i ansible/inventories/lab.ini
ansible-playbook ansible/playbooks/build_images.yml \
  -i ansible/inventories/lab.ini
```

`provision.yml` writes `./kubeconfig` with the API server at
`https://<ansible_host>:6443` (the VPN IP).

```bash
export KUBECONFIG=$(pwd)/kubeconfig
kubectl get nodes   # expect one Ready node (cp1), no control-plane taint blocking pods
```

---

## 4. Workload GitOps + NFs (Nephio)

Management cluster must already exist (see [NEPHIO.md](NEPHIO.md)). Then:

```bash
export KUBECONFIG=$(pwd)/kubeconfig
ansible-playbook ansible/playbooks/workload-gitops.yml \
  -i ansible/inventories/lab.ini --ask-vault-pass \
  -e nephio_git_oran_lab_url=https://github.com/<org>/oran-lab.git \
  -e nephio_git_username=<user> \
  -e nephio_git_token=<token>

# Apply, publish, and verify packages in dependency order.
ansible-playbook ansible/playbooks/deploy-nephio-nfs.yml
```

### Optional: legacy Helm (no mgmt cluster)

```bash
ansible-playbook ansible/playbooks/deploy.yml \
  -i ansible/inventories/lab.ini --ask-vault-pass
```

Deprecated; prefer Nephio when a mgmt cluster is available.

---

## 5. Verify

```bash
export KUBECONFIG=$(pwd)/kubeconfig
kubectl get pods -A
kubectl logs -n ran deployment/ocudu-du -c srsue -f
# Look for: RRC Connected  ->  PDU Session Established

ansible-playbook ansible/playbooks/verify-only.yml -i ansible/inventories/lab.ini
```

---

## 6. Teardown

```bash
ansible-playbook ansible/playbooks/teardown.yml \
  -i ansible/inventories/lab.ini --ask-vault-pass
```

---

## Troubleshooting

| Symptom | Likely cause |
|---------|----------------|
| Ansible / SSH timeout | OpenVPN down, or wrong IP in `lab.ini` |
| `kubectl` cannot reach API | VPN disconnected; `./kubeconfig` points at `ansible_host` (VPN IP) |
| Pods Pending on control-plane | Untaint step failed — re-run `provision.yml`, or manually: `kubectl taint nodes <name> node-role.kubernetes.io/control-plane:NoSchedule-` |
| kubeadm / API cert issues | `control_plane_ip` must match an address on the node (`ip -4 addr`); fix `lab.ini` and re-provision |
| Image pull failures | Vault Docker Hub credentials; re-run `workload-gitops.yml` or `build_images.yml` |

OVS Multus secondary networks (`10.200.x.0/24`) work on a single node. VXLAN
tunnels between nodes are skipped when there is only one host in `k8s_cluster`.
