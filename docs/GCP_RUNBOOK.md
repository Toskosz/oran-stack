# GCP deployment runbook

This is the copy-paste runbook for creating, verifying, tearing down, and
recreating the complete O-RAN lab on GCP.

The deployment uses three GCP VMs:

- `oran-cp1`: workload Kubernetes control plane
- `oran-w1`: workload Kubernetes worker (5G core, RIC, RAN, xApp, monitoring)
- `oran-mgmt`: Nephio/Porch management cluster

The Ansible controller (for example WSL2) is not part of either Kubernetes
cluster. Run every command below from that controller.

## 1. Important behavior

A full VM teardown removes the Kubernetes clusters, disks, local kubeconfigs,
and generated inventories. It deliberately retains:

- the `oran-stack` blueprint Git repository
- the `oran-mgmt` deployment Git repository
- the `oran-lab` workload deployment Git repository
- Docker Hub images

The external Git repositories provide deployment history. On the next build,
`deploy-nephio-nfs.yml` detects an empty or stale workload and republishes the
blueprints. A normal clean rebuild does not require deleting Git repositories.

The deployment automation publishes the exact blueprints in the local checkout
during stale-state recovery. Review local changes before deployment:

```bash
cd ~/oran-testbed/oran-stack
git status
git diff --check
```

Commit and push changes before deploying from another machine or checkout.

## 2. One-time controller prerequisites

Required tools:

- Ansible 2.15 or newer
- Google Cloud CLI
- Docker 24 or newer
- Helm 3.12 or newer
- `kubectl`
- `kpt` and `porchctl` (the Nephio bootstrap installs these when absent)

Authenticate and select the GCP project:

```bash
gcloud auth login
gcloud auth application-default login
gcloud config set project oran-lab
gcloud config get-value project
```

Create the VM SSH key if it does not exist:

```bash
test -f ~/.ssh/oran_gcp || \
  ssh-keygen -t rsa -b 4096 -f ~/.ssh/oran_gcp
```

Install Ansible collections:

```bash
cd ~/oran-testbed/oran-stack/ansible
ansible-galaxy collection install -r requirements.yml
```

Always run Ansible from `oran-stack/ansible/`. This ensures that
`ansible.cfg` loads the project role path and `~/.oran_vault_pass`.

## 3. Docker Hub vault

The image build and workload GitOps playbooks need a Docker Hub personal
access token.

If the vault does not exist:

```bash
cd ~/oran-testbed/oran-stack/ansible
ansible-vault create inventories/group_vars/all/vault.yml
```

Enter:

```yaml
vault_dockerhub_password: "your-docker-hub-pat"
```

Store the corresponding Ansible Vault password:

```bash
read -rsp "Vault password: " VAULT_PASSWORD; echo
printf '%s\n' "$VAULT_PASSWORD" > ~/.oran_vault_pass
unset VAULT_PASSWORD
chmod 600 ~/.oran_vault_pass
```

The Docker Hub username defaults to `x0tok` in
`inventories/group_vars/all/vars.yml`. Override it with
`-e dockerhub_username=...` when necessary.

Verify that Ansible can decrypt the vault:

```bash
ansible-vault view inventories/group_vars/all/vault.yml
```

## 4. GitHub prerequisites

The following repositories must exist:

- `https://github.com/Toskosz/oran-stack.git`
- `https://github.com/Toskosz/oran-mgmt.git`
- `https://github.com/Toskosz/oran-lab.git`

Use a GitHub PAT with read/write access to all three repositories. Load it
without putting it directly in shell history:

```bash
read -rsp "GitHub token: " GITHUB_TOKEN; echo
export GITHUB_TOKEN
export GITHUB_USER=Toskosz
export BLUEPRINTS_REPO=https://github.com/Toskosz/oran-stack.git
export MGMT_REPO=https://github.com/Toskosz/oran-mgmt.git
export ORAN_LAB_REPO=https://github.com/Toskosz/oran-lab.git
```

## 5. Select a GCP zone

The examples use:

```bash
export ORAN_GCP_ZONE=us-east1-b
```

If GCP reports `ZONE_RESOURCE_POOL_EXHAUSTED`, retry with another zone:

```bash
export ORAN_GCP_ZONE=us-east1-c
# Other options: us-east1-d, us-west1-b, europe-west1-b
```

Use the same zone for create and delete commands.

## 6. Full deployment from no VMs

Start in the Ansible directory:

```bash
cd ~/oran-testbed/oran-stack/ansible
```

### Resume checkpoints

The playbooks are intended to be rerunnable. Before continuing a partial build,
select the relevant kubeconfig and inspect the current state.

If this command shows both `cp1` and `w1` as `Ready`:

```bash
export KUBECONFIG=../kubeconfig
kubectl get nodes -o wide
```

the workload provisioning step is complete. Continue at
[6.2 Build and push container images](#62-build-and-push-container-images).

If this command shows `oran-mgmt` as `Ready`:

```bash
export KUBECONFIG=../kubeconfig-mgmt
kubectl get nodes -o wide
```

management provisioning is complete. Continue at
[6.4 Bootstrap Nephio and Porch](#64-bootstrap-nephio-and-porch), unless the
`blueprints`, `mgmt`, and `oran-lab` repositories are already registered and
Ready.

If RootSync already exists:

```bash
kubectl --kubeconfig=../kubeconfig get rootsync \
  oran-lab -n config-management-system -o wide
```

continue at
[6.6 Publish and deploy network functions](#66-publish-and-deploy-network-functions).

### 6.1 Create and provision the workload cluster

Create `oran-cp1` and `oran-w1`:

```bash
ansible-playbook ./playbooks/gcp-vm-create.yml \
  -e gcp_zone="$ORAN_GCP_ZONE"
```

This writes `inventories/gcp.ini`.

Provision kubeadm, Flannel, Multus, OVS-CNI, OVS bridges, storage, and the
workload kubeconfig:

```bash
ansible-playbook ./playbooks/provision.yml \
  -i inventories/gcp.ini
```

Verify the workload cluster:

```bash
export KUBECONFIG=../kubeconfig
kubectl get nodes -o wide
kubectl get pods -A
```

Both nodes should become `Ready`.

### 6.2 Build and push container images

The inventory is required so Ansible loads `group_vars` and the vault:

```bash
ansible-playbook ./playbooks/build_images.yml \
  -i inventories/gcp.ini
```

Do not omit `-i inventories/gcp.ini`; otherwise `dockerhub_password` is
undefined.

### 6.3 Create and provision the management cluster

Create `oran-mgmt`:

```bash
ansible-playbook ./playbooks/gcp-vm-create-mgmt.yml \
  -e gcp_zone="$ORAN_GCP_ZONE"
```

This writes `inventories/mgmt.ini`.

Provision the single-node management kubeadm cluster:

```bash
ansible-playbook ./playbooks/provision-mgmt.yml \
  -i inventories/mgmt.ini
```

Verify it:

```bash
export KUBECONFIG=../kubeconfig-mgmt
kubectl get nodes -o wide
kubectl get pods -A
```

### 6.4 Bootstrap Nephio and Porch

```bash
export KUBECONFIG=../kubeconfig-mgmt

ansible-playbook ./playbooks/bootstrap-nephio.yml \
  -e nephio_git_blueprints_url="$BLUEPRINTS_REPO" \
  -e nephio_git_mgmt_url="$MGMT_REPO" \
  -e nephio_git_oran_lab_url="$ORAN_LAB_REPO" \
  -e nephio_git_username="$GITHUB_USER" \
  -e nephio_git_token="$GITHUB_TOKEN"
```

Verify Porch and the registered repositories:

```bash
kubectl get pods -A
kubectl get repositories
kubectl get repositories -o wide
```

The `blueprints`, `mgmt`, and `oran-lab` repositories must report
`READY=True`.

### 6.5 Enable workload GitOps

```bash
export KUBECONFIG=../kubeconfig

ansible-playbook ./playbooks/workload-gitops.yml \
  -i inventories/gcp.ini \
  -e nephio_git_oran_lab_url="$ORAN_LAB_REPO" \
  -e nephio_git_username="$GITHUB_USER" \
  -e nephio_git_token="$GITHUB_TOKEN"
```

Verify Config Sync:

```bash
kubectl get pods -n config-management-system
kubectl get rootsync -n config-management-system
```

### 6.6 Publish and deploy network functions

For a cold rebuild, explicitly publish fresh revisions from the local
blueprints:

```bash
ansible-playbook ./playbooks/deploy-nephio-nfs.yml \
  -e deploy_force_fresh=true
```

The playbook performs the following sequence:

1. `ns-and-secrets`
2. `5g-core`
3. `mongodb-init`
4. `near-rt-ric`
5. `ran`
6. `verify-e2`
7. `xapp-simple-mon`
8. `xapp-lifecycle`
9. `verify-ue`
10. `monitoring`

It proposes and approves Porch revisions, waits for each Config Sync commit,
and runs the package readiness gates. Ansible stays quiet until the task
finishes; stream detail with `tail -f ../.nephio-deploy.log` from `ansible/`.
`xapp-lifecycle` waits for
AppMgr, resynchronizes RTMgr, restarts and resubscribes the xApp, preserves the
subscription routes, and requires at least one `RIC Indication Received`
message before `verify-ue` proceeds.

For an idempotent retry of an existing deployment:

```bash
ansible-playbook ./playbooks/deploy-nephio-nfs.yml
```

## 7. End-to-end verification

Select the workload cluster:

```bash
export KUBECONFIG=../kubeconfig
```

Check Config Sync:

```bash
kubectl get rootsync oran-lab -n config-management-system -o wide
kubectl get resourcegroup oran-lab -n config-management-system
```

Check all workloads:

```bash
kubectl get pods -A
kubectl get jobs -A
kubectl get deployments -n 5g-core
kubectl get deployments -n near-rt-ric
kubectl get deployments -n ran
kubectl get deployments -n ricxapp
kubectl get deployments -n monitoring
```

Wait for functional gates:

```bash
kubectl wait --for=condition=complete \
  job/mongodb-init -n 5g-core --timeout=900s

kubectl wait --for=condition=complete \
  job/verify-e2 -n oran-verify --timeout=900s

kubectl wait --for=condition=complete \
  job/xapp-lifecycle -n oran-verify --timeout=900s

kubectl wait --for=condition=complete \
  job/verify-ue -n oran-verify --timeout=900s
```

Check UE attachment:

```bash
kubectl logs -n ran deployment/ocudu-du -c srsue --tail=100
```

Expected milestones:

```text
RRC Connected
PDU Session Established
```

Check E2:

```bash
kubectl logs -n near-rt-ric deployment/ric-e2term --tail=100
kubectl logs -n ran deployment/ocudu-du -c ocudu-du --tail=100
kubectl logs -n ricxapp deployment/r4-simple-mon -c xapp --tail=200 | \
  grep -E 'Subscribe to E2 node ID|RIC Indication Received|ApiException|503'
kubectl logs -n oran-verify job/xapp-lifecycle --tail=200
```

## 8. Complete teardown

Stop any active deployment playbook with `Ctrl+C` before teardown. Confirm that
no deployment automation remains:

```bash
pgrep -af 'deploy-nephio-nfs|deploy-oran-lab' || \
  echo "no deployment process running"
```

Reset the workload cluster:

```bash
cd ~/oran-testbed/oran-stack/ansible

ansible-playbook ./playbooks/teardown.yml \
  -i inventories/gcp.ini
```

Reset the management cluster:

```bash
ansible-playbook ./playbooks/teardown-mgmt.yml \
  -i inventories/mgmt.ini
```

Delete workload VMs and their firewall rules:

```bash
ansible-playbook ./playbooks/gcp-vm-delete.yml \
  -e gcp_zone="$ORAN_GCP_ZONE"
```

Delete the management VM:

```bash
ansible-playbook ./playbooks/gcp-vm-delete-mgmt.yml \
  -e gcp_zone="$ORAN_GCP_ZONE"
```

Verify that no VMs remain:

```bash
gcloud compute instances list
```

The playbooks also remove:

- `inventories/gcp.ini`
- `inventories/mgmt.ini`
- `../kubeconfig`
- `../kubeconfig-mgmt`

Git repositories and Docker Hub images remain intact.

## 9. Common failures

### GCP zone capacity exhausted

Symptom:

```text
ZONE_RESOURCE_POOL_EXHAUSTED
```

Retry creation with another zone and retain that zone for deletion:

```bash
export ORAN_GCP_ZONE=us-east1-c
ansible-playbook ./playbooks/gcp-vm-create.yml \
  -e gcp_zone="$ORAN_GCP_ZONE"
```

### Ansible cannot find project roles

Run from the Ansible directory:

```bash
cd ~/oran-testbed/oran-stack/ansible
```

Alternatively, explicitly set:

```bash
export ANSIBLE_CONFIG=~/oran-testbed/oran-stack/ansible/ansible.cfg
```

### `dockerhub_password` is undefined

Use the generated inventory:

```bash
ansible-playbook ./playbooks/build_images.yml \
  -i inventories/gcp.ini
```

Then verify the vault:

```bash
ansible-vault view inventories/group_vars/all/vault.yml
```

### PackageVariants are Ready but no network functions appear

Inspect both clusters:

```bash
kubectl --kubeconfig=../kubeconfig-mgmt get \
  repositories,packagevariants,packagerevisions

kubectl --kubeconfig=../kubeconfig get rootsync \
  oran-lab -n config-management-system -o yaml
```

Republish local blueprints:

```bash
ansible-playbook ./playbooks/deploy-nephio-nfs.yml \
  -e deploy_force_fresh=true
```

### A previous deployment left the deployment lock

First ensure no deployment process is running:

```bash
pgrep -af 'deploy-nephio-nfs|deploy-oran-lab'
```

Inspect the lock:

```bash
kubectl --kubeconfig=../kubeconfig-mgmt get configmap \
  oran-stack-nephio-deploy-lock -n default -o yaml
```

Only when the recorded deployment is no longer running, remove the stale lock:

```bash
kubectl --kubeconfig=../kubeconfig-mgmt delete configmap \
  oran-stack-nephio-deploy-lock -n default
```

### RootSync reports errors

```bash
kubectl --kubeconfig=../kubeconfig get rootsync \
  oran-lab -n config-management-system -o yaml

kubectl --kubeconfig=../kubeconfig logs \
  -n config-management-system \
  -l configsync.gke.io/sync-name=oran-lab \
  -c reconciler --tail=100
```

Do not continue to dependent packages until RootSync is synchronized.

### xApp subscribed but receives no KPM indications

Inspect the lifecycle gate and runtime routes:

```bash
kubectl --kubeconfig=../kubeconfig logs -n oran-verify \
  job/xapp-lifecycle --tail=250
kubectl --kubeconfig=../kubeconfig logs -n near-rt-ric \
  deployment/ric-rtmgr -c rtmgr --since=10m
kubectl --kubeconfig=../kubeconfig logs -n ricxapp \
  deployment/r4-simple-mon -c xapp --tail=250
```

Rerunning `deploy-nephio-nfs.yml` recreates the lifecycle Job and re-applies
the RTMgr/xApp recovery sequence without republishing healthy NF packages.

## 10. Cost and cleanup reminder

The three VMs and their persistent disks incur GCP charges while they exist.
When the lab is not needed, run the complete teardown and verify with:

```bash
gcloud compute instances list
gcloud compute disks list
```
