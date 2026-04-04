# TODO — Manual Intervention Required

This file tracks every step that **cannot be automated** by Ansible or Terraform
and therefore requires direct human action.  Complete these before or during the
deployment process as indicated.

---

## Before running `provision.yml`

### 1. Choose a globally unique GCP project ID
GCP project IDs are **globally unique across all GCP customers**.  You must pick
one yourself.  Rules: 6–30 characters, lowercase letters, digits, and hyphens;
must start with a letter.

**Action:** Edit `ansible/group_vars/all.yml` and replace the placeholder:
```yaml
gcp_project_id: "oran-lab-CHANGEME"
```
Example: `oran-lab-yourname-2026`

---

### 2. Locate your GCP Billing Account ID
Terraform needs a billing account to attach to the new project.  Find yours at:
<https://console.cloud.google.com/billing>

The format is `XXXXXX-XXXXXX-XXXXXX`.

**Action:** Store the real value in an Ansible Vault file to keep it out of git:
```bash
ansible-vault create ansible/group_vars/all.vault.yml
```
Add:
```yaml
gcp_billing_account: "ABCDEF-123456-FEDCBA"
vault_dockerhub_password: "your-docker-hub-token"
```
Then in `ansible/group_vars/all.yml` reference it:
```yaml
gcp_billing_account: "{{ vault_gcp_billing_account }}"
dockerhub_password:  "{{ vault_dockerhub_password }}"
```

---

### 3. Authenticate the gcloud CLI
The `gke_provision` role calls `gcloud container clusters get-credentials` to
write a kubeconfig entry after Terraform creates the cluster.

**Action:**
```bash
gcloud auth login
gcloud auth application-default login   # used by the Terraform Google provider
```

---

### 4. Install required tools on the Ansible controller
The playbooks assume the following binaries are available on your `localhost`:

| Tool | Min version | Install |
|------|-------------|---------|
| `ansible` | 2.15 | `pip install ansible` |
| `terraform` | 1.6 | <https://developer.hashicorp.com/terraform/install> |
| `gcloud` CLI | latest | <https://cloud.google.com/sdk/docs/install> |
| `helm` | 3.14 | <https://helm.sh/docs/intro/install/> |
| `kubectl` | matches cluster | installed by gcloud or standalone |
| `docker` | 24+ | <https://docs.docker.com/engine/install/> |

Install Ansible collections:
```bash
ansible-galaxy collection install -r ansible/requirements.yml
```

---

### 5. Create Docker Hub credentials
The `container_images` role pushes images to your Docker Hub account.

**Action:**
- Create a Docker Hub account if you do not have one: <https://hub.docker.com>
- Create a **Personal Access Token** (PAT) with Read/Write scope:
  <https://hub.docker.com/settings/security>
- Store the PAT in `all.vault.yml` as `vault_dockerhub_password`
- Set your username in `ansible/group_vars/all.yml`:
  ```yaml
  dockerhub_username: "your-dockerhub-username"
  ```

---

### 6. Verify GCP APIs will be enabled by Terraform
`terraform/main.tf` enables the following GCP APIs.  The `terraform apply` will
fail if the account running it does not have `serviceusage.services.enable`
permission on the **billing account's parent organization** (or if APIs are
blocked by an org policy).

APIs enabled:
- `container.googleapis.com` (GKE)
- `compute.googleapis.com` (VPC, NAT)
- `iam.googleapis.com`
- `cloudresourcemanager.googleapis.com`

**Action:** Confirm with your GCP organization admin if you are working in a
corporate GCP organization, or proceed directly if you own the billing account.

---

## After `provision.yml` — before `deploy.yml`

### 7. Verify SCTP kernel module on GKE nodes
The DaemonSet `daemonset-sctp-init` loads the `sctp` kernel module on every
node at startup.  Verify it is working:

```bash
kubectl logs -n 5g-core -l app=sctp-init --tail=20
# Expected: "sctp module loaded" or "sctp already loaded"

# Also verify from inside a node (requires SSH to a node via IAP):
gcloud compute ssh <node-name> --zone us-central1-a -- lsmod | grep sctp
```

If the module load fails, the `amf-ngap` and `e2term` SCTP Services will not
work.  GKE >= 1.28 is required; the Terraform cluster spec pins `kubernetes_version = "1.30"`.

---

### 8. Note the LoadBalancer IPs for external access
After `deploy.yml` completes, retrieve the externally reachable IPs:

```bash
# AMF NGAP (SCTP, port 38412) — needed for real gNBs outside the cluster
kubectl get svc -n 5g-core amf-ngap

# e2term (SCTP, port 36421) — needed for real DUs outside the cluster
kubectl get svc -n near-rt-ric e2term

# WebUI (HTTP, port 9999)
kubectl get svc -n 5g-core webui
```

These IPs are also printed by the `deploy_5g_core` and `deploy_ric` roles.

---

### 9. Add a subscriber via WebUI
Before the UE can attach, its IMSI must exist in the Open5GS subscriber
database.  The `init-webui-data.js` init script seeds one test subscriber
automatically, but you may need to verify or add your own.

**Action:**
1. Open `http://<webui-external-ip>:9999` in a browser
2. Login: `admin` / `1423` — **change this password immediately**
3. Navigate to Subscribers → Add subscriber
4. IMSI: `001010000000001`, K: `465B5CE8B199B49FAA5F0A2EE238A6BC`,
   OPc: `E8ED289DEBA952E4283B54E88E6183CA`
   (these match `helm/ran/values.yaml ue:` defaults)

---

### 10. 4G EPC NFs will crash on startup
The MME, SGW-C, SGW-U, HSS, and PCRF containers are deployed (when
`mme.enabled: true` in `helm/5g-core/values.yaml`) but are known to exit with
signal 139 (segfault) on startup.  This is a known issue with running the Open5GS
4G EPC in containerised environments without the expected kernel modules and
network setup.

**Action:** Either:
- Set `mme.enabled: false` in `helm/5g-core/values.yaml` before deploying
  (safe — not needed for 5G SA operation), or
- Accept the crash-loop and ignore the unhealthy Deployments for those NFs.

The 5G SA NFs (AMF, SMF, UPF, NRF, etc.) are unaffected.

---

### 11. UPF TUN interface — verify data plane
The UPF runs with `hostNetwork: true` and creates a TUN interface (`ogstun`) on
the GKE node.  Verify it was created:

```bash
# Get the node the UPF pod is running on
kubectl get pod -n 5g-core -l app=upf -o wide

# SSH to that node and check
gcloud compute ssh <node-name> --zone us-central1-a -- ip addr show ogstun
```

If the TUN is missing, check UPF logs:
```bash
kubectl logs -n 5g-core deployment/upf
```

---

## Teardown

### 12. Run teardown before abandoning the GCP project
GCP will continue to bill for the GKE cluster and LoadBalancers even when pods
are not running.  When done with the lab:

```bash
ansible-playbook ansible/playbooks/teardown.yml \
  -e gcp_project_id=<your-project-id> \
  -e gcp_billing_account=<your-billing-account> \
  --ask-vault-pass
```

Alternatively, delete the GCP project directly in the console:
<https://console.cloud.google.com/iam-admin/projects>
