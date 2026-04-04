# CLOUD.md — Architectural & Technical Decision Guide

This document explains **every significant architectural and technical decision**
made when migrating the `oran-stack` Docker Compose lab to Google Kubernetes
Engine (GKE), managed by Ansible + Terraform.  It is written as a learning guide:
each section asks *why* a decision was made, not just *what* was done.

---

## Table of Contents

1. [Why GKE instead of a self-managed cluster?](#1-why-gke-instead-of-a-self-managed-cluster)
2. [Why Terraform for infrastructure provisioning?](#2-why-terraform-for-infrastructure-provisioning)
3. [Why Ansible as the outer orchestrator?](#3-why-ansible-as-the-outer-orchestrator)
4. [Why Helm for Kubernetes packaging?](#4-why-helm-for-kubernetes-packaging)
5. [Why three separate Helm charts?](#5-why-three-separate-helm-charts)
6. [Why three separate Kubernetes namespaces?](#6-why-three-separate-kubernetes-namespaces)
7. [Why private Docker Hub instead of GCR/Artifact Registry?](#7-why-private-docker-hub-instead-of-gcr-artifact-registry)
8. [Why values.yaml replaces .env?](#8-why-valuesyaml-replaces-env)
9. [Why no image changes for config templating?](#9-why-no-image-changes-for-config-templating)
10. [Why 0.0.0.0 binds and DNS names in NF configs?](#10-why-0000-binds-and-dns-names-in-nf-configs)
11. [Why a DaemonSet for SCTP kernel module loading?](#11-why-a-daemonset-for-sctp-kernel-module-loading)
12. [Why hostNetwork for the UPF?](#12-why-hostnetwork-for-the-upf)
13. [Why a StatefulSet with PersistentVolumeClaim for MongoDB?](#13-why-a-statefulset-with-persistentvolumeclaim-for-mongodb)
14. [Why initContainers for RIC startup ordering?](#14-why-initcontainers-for-ric-startup-ordering)
15. [Why hostAliases for rtmgr?](#15-why-hostaliases-for-rtmgr)
16. [Why Downward API for e2term's external FQDN?](#16-why-downward-api-for-e2terms-external-fqdn)
17. [Why LoadBalancer Services for SCTP?](#17-why-loadbalancer-services-for-sctp)
18. [Why Ansible Vault for secrets?](#18-why-ansible-vault-for-secrets)
19. [Why preemptible nodes for the GKE node pool?](#19-why-preemptible-nodes-for-the-gke-node-pool)
20. [Why Autopilot OFF for GKE?](#20-why-autopilot-off-for-gke)
21. [Why private nodes + Cloud NAT?](#21-why-private-nodes--cloud-nat)
22. [Known limitations and accepted trade-offs](#22-known-limitations-and-accepted-trade-offs)

---

## 1. Why GKE instead of a self-managed cluster?

**Context:** The original stack runs on a single laptop with Docker Compose.
Moving to the cloud requires a managed Kubernetes platform.

**Decision:** Google Kubernetes Engine (GKE) Standard mode.

**Why:**
- GKE handles control-plane upgrades, certificates, and etcd backups — removing
  the largest operational burden of self-managing a cluster.
- The Google Cloud provider for Terraform is mature and has first-class support
  for GKE via the `google_container_cluster` resource.
- GKE >= 1.28 supports `protocol: SCTP` in Services, which is required for the
  AMF NGAP (N2) and e2term E2 interfaces.  Older managed Kubernetes offerings
  (EKS < 1.27, AKS) had lagging SCTP support at the time of this migration.
- GCP's `pd-ssd` persistent disks, exposed as the `standard-rwo` StorageClass,
  provide ReadWriteOnce volumes suitable for MongoDB's single-writer pattern.

---

## 2. Why Terraform for infrastructure provisioning?

**Context:** We need to create a GCP project, enable APIs, create a VPC, a Cloud
NAT gateway, IAM service accounts, and a GKE cluster.  These are long-lived
infrastructure resources (not application state).

**Decision:** HashiCorp Terraform with the `google` and `google-beta` providers.

**Why:**
- Terraform's state file tracks exactly which resources exist, so re-running
  `terraform apply` is safe and idempotent — it only changes what has drifted.
- It models the **dependency graph** between resources (e.g., the subnet must
  exist before the GKE cluster can reference it) automatically.
- `terraform destroy` removes everything in the correct order, avoiding orphaned
  resources that would keep billing.
- `terraform output` produces machine-readable values (cluster name, endpoint,
  project ID) that Ansible can consume to configure kubectl.

**Alternative considered:** Using `gcloud` CLI commands in Ansible tasks.
Rejected because `gcloud` is imperative — re-running creates duplicate resources
unless you write explicit "check if exists" guards, which defeats the purpose.

---

## 3. Why Ansible as the outer orchestrator?

**Context:** We need to: (a) run Terraform, (b) build and push Docker images,
(c) configure kubectl, and (d) run `helm install`.  These are four different
tools with different CLIs.

**Decision:** Ansible drives everything via playbooks and roles.

**Why:**
- Ansible provides a single entry point (`ansible-playbook`) for the entire
  lifecycle, hiding tool-specific CLI complexity behind declarative task lists.
- The `cloud.terraform` Ansible collection wraps Terraform as a native task,
  passing variables cleanly without shell escaping.
- The `kubernetes.core.helm` module wraps Helm, allowing Helm values to be
  expressed as a YAML dict inside the playbook rather than a long `--set` chain.
- The `community.docker` collection handles Docker build + push with proper
  secret handling (`no_log: true`) so credentials never appear in logs.
- Ansible Vault encrypts secrets at rest inside the repository.

**Alternative considered:** A `Makefile` with shell targets calling each tool.
Rejected because it has no secret management, no idempotency, and poor
cross-platform portability.

---

## 4. Why Helm for Kubernetes packaging?

**Context:** Each stack (5G core, RIC, RAN) consists of multiple Deployments,
Services, ConfigMaps, and a StatefulSet.  These need to be parameterised
(different image tags, PLMNs, etc. per environment).

**Decision:** Helm charts — one per stack.

**Why:**
- Helm's `values.yaml` provides a clean override mechanism.  The same chart
  can be deployed to a test environment (PLMN 001/01) and a production
  environment (PLMN 310/260) by overriding just a few values.
- `helm upgrade --install` is idempotent — run it twice and the second run is
  a no-op if nothing changed.
- `helm uninstall` removes all resources associated with a release atomically.
- `_helpers.tpl` shared template functions (`commonEnv`, `nfVolumeMounts`, etc.)
  eliminate copy-paste across 17 Deployment templates.

**Alternative considered:** Raw `kubectl apply -k` (Kustomize).
Kustomize lacks a native values system — it patches YAML files rather than
templating them, making parameterisation awkward for this many variables.

---

## 5. Why three separate Helm charts?

**Context:** The original repo has three Docker Compose files:
`docker-compose.yml` (core), `docker-compose.ric.yml` (RIC),
`docker-compose.cudu.yml` (RAN).

**Decision:** One Helm chart per compose file: `helm/5g-core/`,
`helm/near-rt-ric/`, `helm/ran/`.

**Why:**
- Matches the existing operational boundary — operators often bring up the core
  before the RIC, and the RAN last.  Separate charts allow independent
  `helm upgrade` without touching the other stacks.
- Aligns with namespace separation (see §6).
- Keeps each chart's `values.yaml` focused on its stack, reducing cognitive load.
- Enables the `deploy.yml` playbook to enforce startup ordering at the play level
  (play 1 = core, play 2 = RIC, play 3 = RAN), with each play's `wait: true`
  ensuring the previous stack is healthy before proceeding.

---

## 6. Why three separate Kubernetes namespaces?

**Context:** In Docker Compose, the three stacks are isolated by separate Docker
networks (5g-core-network, ric-network, ran-network) with `extra_hosts` for
cross-network names.

**Decision:** Three namespaces — `5g-core`, `near-rt-ric`, `ran`.

**Why:**
- Kubernetes namespaces provide the same DNS scope isolation that Docker networks
  provide.  A service named `nrf` in `5g-core` does not conflict with a
  hypothetical `nrf` in another namespace.
- RBAC policies can be scoped per namespace, isolating blast radius.
- Cross-namespace DNS (`nrf.5g-core.svc.cluster.local`) is explicit and
  unambiguous, replacing the Docker `extra_hosts` hacks.
- `imagePullSecrets` are namespace-scoped; creating one per namespace with the
  same Docker Hub credentials is straightforward.

---

## 7. Why private Docker Hub instead of GCR/Artifact Registry?

**Context:** Open5GS and srsRAN images are built from source (the Dockerfiles in
this repo are customised).  They need to live in a private registry so
`imagePullSecrets` work.

**Decision:** Docker Hub private repositories.

**Why:**
- Docker Hub is registry-agnostic — no GCP-specific configuration needed.
  The same images work on a different cloud or local cluster by updating
  `imagePullSecrets`.
- GCR / Artifact Registry would couple the image pipeline to GCP, requiring
  Workload Identity or Service Account key management for push access.
- The `community.docker` Ansible collection has mature support for Docker Hub
  login, build, and push without additional GCP tooling.

**Trade-off:** Docker Hub free tier has rate limits on pulls (100/6h
unauthenticated, 200/6h authenticated).  The `imagePullSecret` in each namespace
authenticates pulls, so the 200/6h limit applies.  For a lab with 2 nodes this
is sufficient.

---

## 8. Why values.yaml replaces .env?

**Context:** The original repo uses a `.env` file as the single source of truth
for all configuration.  Docker Compose injects these as environment variables
into containers via `env_file: .env`.

**Decision:** Each chart's `values.yaml` is the new single source of truth.
Container `env:` blocks in Deployment templates replace `env_file:`.

**Why:**
- `values.yaml` is a Kubernetes-native mechanism.  Helm templates read from it
  directly (`{{ .Values.plmn.mcc }}`), producing typed, validated YAML.
- `.env` has no type system or nested structure.  `values.yaml` uses nested
  maps (e.g., `plmn.mcc`, `amf.ngapPort`), which is more expressive and
  self-documenting.
- `helm upgrade --set plmn.mcc=310` is cleaner than editing `.env` and
  restarting containers.
- The same `values.yaml` acts as documentation of all configurable parameters.

---

## 9. Why no image changes for config templating?

**Context:** Each Open5GS NF reads its config from a YAML file at
`/etc/open5gs/<nf>.yaml`.  In Docker Compose, `entrypoint.sh` runs `envsubst`
on a template to produce the final config file at startup.

**Discovery:** `entrypoint.sh` already uses `envsubst` to render templates.
The templates use `${VAR}` placeholders that map 1:1 to `.env` variables.

**Decision:** Use the same mechanism in Kubernetes.  Templates are placed in a
`ConfigMap` and mounted at `/etc/open5gs/`.  Container `env:` blocks supply the
`${VAR}` values.  `entrypoint.sh` runs `envsubst` exactly as before.

**Why this matters:** Not modifying the images keeps the migration incremental
and reversible.  The same Docker image works in both Docker Compose (dev) and
Kubernetes (cloud) — only the environment variables differ.

---

## 10. Why 0.0.0.0 binds and DNS names in NF configs?

**Context:** The original NF configs use hardcoded Docker subnet IPs like
`172.20.0.10` for NRF.  In Kubernetes, pod IPs are assigned dynamically.

**Decision:** All NF configs were updated to:
1. Use `address: 0.0.0.0` for the NF's own listen address.
2. Use Kubernetes DNS service names (e.g., `nrf`, `scp`, `upf`) for peer
   addresses.

**Why:**
- Pods in Kubernetes are ephemeral — their IP changes every time a pod is
  rescheduled.  Hardcoded IPs are broken by design.
- Kubernetes automatically creates DNS A records for Services.  A Service named
  `nrf` in namespace `5g-core` is reachable at `nrf` (within the namespace) or
  `nrf.5g-core.svc.cluster.local` (from other namespaces).
- `0.0.0.0` means "listen on all interfaces" — the kubelet assigns the pod's
  interface IP at runtime, which is what peers connect to.

---

## 11. Why a DaemonSet for SCTP kernel module loading?

**Context:** SCTP (Stream Control Transmission Protocol) is used by AMF NGAP
(N2 interface, port 38412) and e2term E2 (port 36421).  GKE nodes run Container-
Optimized OS (COS), which does not auto-load the `sctp` kernel module.

**Decision:** A DaemonSet (`daemonset-sctp-init.yaml`) with an `initContainer`
that runs `nsenter --target 1 --mount --uts --ipc --net --pid -- modprobe sctp`
on every node.

**Why:**
- A DaemonSet runs exactly one Pod per node, so the module is loaded on every
  node that could schedule the AMF or e2term pods.
- `nsenter --target 1` enters the host's PID 1 (systemd) namespace, so
  `modprobe` affects the host kernel rather than the container's isolated view.
- This approach requires a privileged `initContainer` (necessary for `nsenter`)
  but the main DaemonSet container can be a simple `pause` that does nothing —
  minimising the attack surface of a long-running privileged container.
- **GKE version requirement:** SCTP in Kubernetes Services requires the
  `SCTPSupport` feature gate, which became GA in Kubernetes 1.20 and is
  enabled by default on GKE >= 1.28.  The Terraform cluster spec sets
  `kubernetes_version = "1.30"` to guarantee this.

---

## 12. Why hostNetwork for the UPF?

**Context:** The UPF (User Plane Function) creates TUN interfaces (`ogstun`,
`ogstun2`, `ogstun3`) and sets iptables MASQUERADE rules for UE traffic.  These
operations affect the **host network namespace**, not the pod's namespace.

**Decision:** `hostNetwork: true`, `privileged: true` in the UPF Deployment,
plus `dnsPolicy: ClusterFirstWithHostNet`.

**Why:**
- `hostNetwork: true` gives the UPF pod direct access to the node's network
  interfaces and routing table.  The TUN interfaces and iptables rules the UPF
  creates are visible to the node and persist after the container runs.
- `entrypoint.sh` already handles TUN creation and iptables setup — no image
  changes needed.
- `dnsPolicy: ClusterFirstWithHostNet` is required when `hostNetwork: true` to
  preserve in-cluster DNS resolution.  Without it, the pod uses the node's
  `/etc/resolv.conf`, which does not contain `cluster.local` DNS entries,
  breaking name resolution for `nrf`, `smf`, etc.
- **Trade-off:** The UPF pod has elevated privileges.  In a production
  deployment you would isolate it on a dedicated node pool with appropriate
  NodeSelectors and taints.

---

## 13. Why a StatefulSet with PersistentVolumeClaim for MongoDB?

**Context:** In Docker Compose, MongoDB uses a named volume (`mongodb_data`) for
persistence.  In Kubernetes, Deployments are stateless by design.

**Decision:** MongoDB is deployed as a `StatefulSet` with a
`volumeClaimTemplate` backed by `storageClass: standard-rwo` (GCP `pd-ssd`,
20 Gi).

**Why:**
- `StatefulSet` guarantees a stable pod name (`mongodb-0`) and a stable
  PersistentVolumeClaim (`data-mongodb-0`) that survives pod rescheduling.
- `ReadWriteOnce` (RWO) is correct for MongoDB single-instance: only one node
  mounts the disk at a time.
- `standard-rwo` is GKE's SSD StorageClass — faster random I/O than the HDD
  `standard` class, which matters for MongoDB's write journal.
- The `init-mongodb.js` and `init-webui-data.js` scripts are placed in a
  `ConfigMap` and mounted at `/docker-entrypoint-initdb.d/`, where the official
  MongoDB Docker image automatically executes them on first startup.

---

## 14. Why initContainers for RIC startup ordering?

**Context:** Docker Compose's `depends_on` with `condition: service_healthy`
controls startup ordering.  Kubernetes has no direct equivalent.

**Decision:** `initContainers` in each Deployment that depends on another
service being ready.

**Why:**
- An `initContainer` must complete successfully (exit 0) before the main
  container starts.  This is the Kubernetes-idiomatic way to enforce ordering.
- For the `e2term` 5-second startup delay: a `busybox sleep 5` `initContainer`
  replaces the Docker Compose `depends_on: e2mgr: condition: service_started`
  with a fixed delay.  The delay prevents the RMR (Routing Manager) keep-alive
  race condition where e2term tries to connect to rtmgr before rtmgr has
  registered its routing table entry.
- For service availability checks: `initContainers` can use `wget` or `nc` to
  poll a service endpoint, replacing the `healthcheck:` blocks in Docker Compose.

---

## 15. Why hostAliases for rtmgr?

**Context:** The `rtmgr` (Routing Manager) component hardcodes the DNS name
`service-ricplt-submgr-http.ricplt` for submgr's HTTP endpoint.  This name does
not match the Kubernetes Service name in the `near-rt-ric` namespace.

**Discovery:** In the Docker Compose file, this is handled with `extra_hosts`:
```yaml
extra_hosts:
  - "service-ricplt-submgr-http.ricplt:172.22.0.212"
```

**Decision:** Use `hostAliases` in the rtmgr Deployment spec, pointing
`service-ricplt-submgr-http.ricplt` at the ClusterIP of the `submgr` Service.

**Why:**
- `hostAliases` is the Kubernetes equivalent of `/etc/hosts` entries for a Pod.
  Unlike DNS overrides, it works regardless of the cluster DNS configuration.
- The actual value injected is the submgr Service ClusterIP, discovered at
  deploy time via `kubectl get svc submgr -n near-rt-ric -o jsonpath=...`.
- An alternative would be to create a Kubernetes Service named
  `service-ricplt-submgr-http` in a namespace named `ricplt`, but that adds
  an unnecessary namespace just to satisfy a hardcoded name.
- **Note:** The `hostAliases` approach breaks if the submgr Service ClusterIP
  changes (e.g., after a full cluster rebuild).  The deploy role would need to
  re-run `helm upgrade` to refresh the alias.

---

## 16. Why Downward API for e2term's external FQDN?

**Context:** The `e2term` config (`config.conf`) includes:
```
external-fqdn=<ip>
```
This is the IP advertised to the DU during E2 Setup.  In Docker Compose it was
hardcoded as `172.22.0.210`.  In Kubernetes, the pod IP is dynamic.

**Decision:** Use the Kubernetes Downward API to inject the pod's IP as an
environment variable `RIC_E2TERM_SERVICE_HOST`, which `entrypoint.sh` passes
to `envsubst` when rendering `config.conf`.

```yaml
env:
  - name: RIC_E2TERM_SERVICE_HOST
    valueFrom:
      fieldRef:
        fieldPath: status.podIP
```

**Why:**
- The Downward API is the official Kubernetes mechanism for pods to learn their
  own metadata (pod IP, node name, namespace, etc.) without querying the API
  server at runtime.
- This avoids baking the pod IP into a ConfigMap (which would be stale after
  rescheduling) or running a discovery sidecar.
- **Trade-off:** The DU needs to reach e2term at the *pod* IP, not a Service IP,
  because SCTP multi-homing requires the real endpoint.  For pods inside the
  cluster, the LoadBalancer Service IP is used instead.

---

## 17. Why LoadBalancer Services for SCTP?

**Context:** SCTP traffic (AMF NGAP, e2term E2) must be reachable from:
(a) pods inside the cluster (the DU pod connecting to e2term), and
(b) potentially real external gNBs/DUs.

**Decision:** Two `type: LoadBalancer` Services with `protocol: SCTP`:
- `amf-ngap` in namespace `5g-core` (port 38412)
- `e2term` in namespace `near-rt-ric` (port 36421)

**Why:**
- `NodePort` services for SCTP are technically possible but unreliable on GKE
  because kube-proxy's IPVS mode does not support SCTP NAT on older kernel
  versions.  LoadBalancer bypasses kube-proxy and uses GCP's Network Load
  Balancer, which handles SCTP natively.
- GCP Network Load Balancers are Layer 4 (TCP/UDP/SCTP pass-through), preserving
  the SCTP association identifiers that the AMF and e2term need.
- **Within-cluster SCTP:** Pods connecting to each other via ClusterIP Services
  with `protocol: SCTP` work correctly on GKE >= 1.28 with the `sctp` module
  loaded (see §11).

---

## 18. Why Ansible Vault for secrets?

**Context:** Several secrets are needed: Docker Hub password, GCP billing
account ID.  These must not be committed to git in plaintext.

**Decision:** Ansible Vault encrypts secrets in `ansible/group_vars/all.vault.yml`.

**Why:**
- Ansible Vault uses AES-256 encryption.  The encrypted file is safe to commit
  to git — it is useless without the vault password.
- `--ask-vault-pass` prompts for the password at playbook runtime.
- Alternative: HashiCorp Vault or GCP Secret Manager.  Both are better for
  production, but add operational complexity for a lab.  Ansible Vault is
  self-contained and requires no additional infrastructure.

---

## 19. Why preemptible nodes for the GKE node pool?

**Context:** The lab runs in GCP where compute costs money 24/7.

**Decision:** `preemptible = true` in the Terraform node pool spec.

**Why:**
- Preemptible (spot) VMs are ~80% cheaper than on-demand.
- GCP can reclaim them with 30 seconds notice, but for a lab that is acceptable.
- 5G NF pods are stateless (except MongoDB) and restart cleanly after eviction.
- MongoDB's persistent disk survives node preemption because it is detached and
  re-attached to the replacement node.
- **Production note:** Never use preemptible nodes for the control plane (GKE
  manages that) or for stateful workloads in production.

---

## 20. Why Autopilot OFF for GKE?

**Context:** GKE offers two modes: Autopilot (Google manages nodes) and Standard
(you manage nodes).

**Decision:** Standard mode (`enable_autopilot = false`).

**Why:**
- The UPF requires `privileged: true` and `hostNetwork: true`.  GKE Autopilot
  **blocks privileged pods** by design — it is a security restriction that cannot
  be overridden.
- The SCTP DaemonSet also requires a privileged `initContainer` (for `nsenter`),
  which Autopilot would reject.
- Standard mode gives full control over node pool configuration, including the
  node OS, disk type, and machine type.

---

## 21. Why private nodes + Cloud NAT?

**Context:** GKE nodes need to pull container images from Docker Hub and Nexus3
without having public IPs.

**Decision:** Private nodes (`enable_private_nodes = true`) + Cloud NAT gateway.

**Why:**
- Private nodes have no public IP address, reducing the attack surface.
  Kubernetes API access is via the GKE private endpoint (accessible from the
  Ansible controller via authorized networks or Cloud Shell).
- Cloud NAT provides outbound internet access for private nodes — needed for
  image pulls, OS updates, and calling Google APIs.
- Without Cloud NAT, private nodes cannot reach Docker Hub or Nexus3 and pod
  startup would fail with `ImagePullBackOff`.
- The Terraform `main.tf` provisions the Cloud NAT router in the same VPC region
  as the cluster, ensuring all node traffic routes through it.

---

## 22. Known limitations and accepted trade-offs

| Area | Limitation | Accepted? |
|------|-----------|-----------|
| CU multi-homing | Docker Compose gives the CU two IPs (core-network and ran-network). In K8s this is approximated with `0.0.0.0` binds and ClusterIP Services — the CU has a single IP. | Yes — ZMQ virtual radio does not require true multi-homing. |
| 4G EPC NFs | MME, SGW-C, SGW-U, HSS, PCRF crash on startup (signal 139). Deployed but non-functional. | Yes — not needed for 5G SA. Set `mme.enabled: false` to skip. |
| e2term pod IP | The DU's `e2term.near-rt-ric.svc.cluster.local` DNS name resolves to the LoadBalancer IP, not the pod IP. For in-cluster ZMQ UE this is fine. A real external DU needs the LoadBalancer IP. | Yes for lab use. |
| hostAliases for rtmgr | Depends on submgr ClusterIP not changing. Requires `helm upgrade` after cluster rebuild. | Yes for lab use. |
| Single MongoDB replica | MongoDB is deployed as a single replica set member (`rs0`). No replication or automatic failover. | Yes — this is a lab, not production. |
| UPF on a shared node | UPF uses `hostNetwork: true` on one of the 2 cluster nodes. Other pods on the same node share the host network namespace. | Yes for lab use. Mitigate with `nodeAffinity` in production. |
| Preemptible nodes | Cluster can be forcibly stopped by GCP at any time. | Yes for lab use. |
