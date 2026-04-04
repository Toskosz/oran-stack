# ============================================================================
# Main Terraform Configuration — O-RAN Lab GKE Cluster on GCP
# ============================================================================
# Creates, in order:
#   1. GCP project + billing link + API enablement
#   2. VPC network + subnet (VPC-native / alias-IP)
#   3. Cloud Router + Cloud NAT  (outbound internet for private nodes)
#   4. IAM service account for Ansible
#   5. GKE cluster (private nodes, no default pool)
#   6. GKE node pool (n2-standard-4, preemptible, cos_containerd)
# ============================================================================

# ----------------------------------------------------------------------------
# 1. GCP Project
# ----------------------------------------------------------------------------

resource "google_project" "oran_lab" {
  name            = var.gcp_project_name
  project_id      = var.gcp_project_id
  billing_account = var.gcp_billing_account

  # Auto-create a default network — we immediately delete it below and create
  # our own VPC to maintain full control over subnet CIDRs.
  auto_create_network = false
}

# Enable all required GCP APIs. Terraform applies these in parallel where
# possible; resources that depend on them will wait via depends_on.
locals {
  required_apis = [
    "compute.googleapis.com",
    "container.googleapis.com",
    "iam.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "servicenetworking.googleapis.com",
  ]
}

resource "google_project_service" "apis" {
  for_each = toset(local.required_apis)

  project                    = google_project.oran_lab.project_id
  service                    = each.value
  disable_on_destroy         = false
  disable_dependent_services = false

  depends_on = [google_project.oran_lab]
}

# ----------------------------------------------------------------------------
# 2. VPC Network + Subnet (VPC-native / alias-IP)
# ----------------------------------------------------------------------------
# VPC-native mode is required for GKE private clusters. It allocates a
# secondary IP range for pods and another for services from the same VPC,
# enabling pod-to-pod routing without extra NAT.

resource "google_compute_network" "oran_lab" {
  name                    = var.vpc_name
  project                 = google_project.oran_lab.project_id
  auto_create_subnetworks = false # We manage subnets explicitly.

  depends_on = [google_project_service.apis]
}

resource "google_compute_subnetwork" "oran_lab" {
  name          = "${var.vpc_name}-subnet"
  project       = google_project.oran_lab.project_id
  region        = var.gcp_region
  network       = google_compute_network.oran_lab.id
  ip_cidr_range = var.subnet_cidr

  # Secondary ranges are required for VPC-native GKE.
  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = var.pods_cidr
  }
  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = var.services_cidr
  }

  # Allow pods to communicate with the GKE control plane.
  private_ip_google_access = true
}

# ----------------------------------------------------------------------------
# 3. Cloud Router + Cloud NAT
# ----------------------------------------------------------------------------
# Private nodes have no public IP. Cloud NAT provides outbound-only internet
# access (for Docker Hub image pulls, apt packages, etc.) without exposing
# nodes to inbound connections from the internet.

resource "google_compute_router" "oran_lab" {
  name    = "${var.vpc_name}-router"
  project = google_project.oran_lab.project_id
  region  = var.gcp_region
  network = google_compute_network.oran_lab.id
}

resource "google_compute_router_nat" "oran_lab" {
  name                               = "${var.vpc_name}-nat"
  project                            = google_project.oran_lab.project_id
  router                             = google_compute_router.oran_lab.name
  region                             = var.gcp_region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

# Firewall: allow internal traffic within the VPC (node-to-node, pod-to-pod).
resource "google_compute_firewall" "allow_internal" {
  name    = "${var.vpc_name}-allow-internal"
  project = google_project.oran_lab.project_id
  network = google_compute_network.oran_lab.id

  allow {
    protocol = "tcp"
  }
  allow {
    protocol = "udp"
  }
  allow {
    protocol = "icmp"
  }
  allow {
    protocol = "sctp" # Required for N2 (NGAP) and E2 interfaces.
  }

  source_ranges = [
    var.subnet_cidr,
    var.pods_cidr,
    var.services_cidr,
    var.master_cidr,
  ]
}

# Firewall: allow health checks from GCP load-balancer probers.
resource "google_compute_firewall" "allow_lb_health_checks" {
  name    = "${var.vpc_name}-allow-lb-hc"
  project = google_project.oran_lab.project_id
  network = google_compute_network.oran_lab.id

  allow {
    protocol = "tcp"
  }

  # GCP health-check probe source ranges (documented by Google).
  source_ranges = ["35.191.0.0/16", "130.211.0.0/22"]
}

# ----------------------------------------------------------------------------
# 4. IAM Service Account for Ansible
# ----------------------------------------------------------------------------
# Ansible uses this SA (via ADC or key file) to call the GKE and Compute APIs.

resource "google_service_account" "ansible" {
  account_id   = "ansible-deployer"
  display_name = "Ansible GKE Deployer"
  project      = google_project.oran_lab.project_id

  depends_on = [google_project_service.apis]
}

resource "google_project_iam_member" "ansible_container_admin" {
  project = google_project.oran_lab.project_id
  role    = "roles/container.admin"
  member  = "serviceAccount:${google_service_account.ansible.email}"
}

resource "google_project_iam_member" "ansible_compute_viewer" {
  project = google_project.oran_lab.project_id
  role    = "roles/compute.viewer"
  member  = "serviceAccount:${google_service_account.ansible.email}"
}

resource "google_project_iam_member" "ansible_sa_token_creator" {
  project = google_project.oran_lab.project_id
  role    = "roles/iam.serviceAccountTokenCreator"
  member  = "serviceAccount:${google_service_account.ansible.email}"
}

# ----------------------------------------------------------------------------
# 5. GKE Cluster
# ----------------------------------------------------------------------------
# autopilot = false: We need privileged pods (UPF hostNetwork, SCTP DaemonSet).
# Autopilot enforces a restricted security policy that blocks these workloads.
#
# remove_default_node_pool = true: Creates the cluster with a temporary
# default pool which is immediately removed; our controlled pool is added next.
# This is the recommended pattern to avoid the default pool's fixed config.
#
# Private nodes: nodes have no public IP. The control plane is accessed via
# its private endpoint from within the VPC (or via IAP tunnel).

resource "google_container_cluster" "oran_lab" {
  provider = google-beta

  name     = var.cluster_name
  project  = google_project.oran_lab.project_id
  location = var.gcp_zone # Zonal cluster: one zone, lower cost for lab use.

  # Bootstrap: cluster must have at least one node pool at creation time.
  # We remove it and use our own pool below.
  remove_default_node_pool = true
  initial_node_count       = 1

  min_master_version = var.kubernetes_version

  network    = google_compute_network.oran_lab.id
  subnetwork = google_compute_subnetwork.oran_lab.id

  # VPC-native (alias-IP) networking. Required for private clusters.
  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  # Private cluster: nodes have RFC-1918 IPs only.
  # The master's private endpoint is reachable from within the VPC.
  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false # Allow kubectl from outside VPC via public master endpoint.
    master_ipv4_cidr_block  = var.master_cidr
  }

  # Allow all CIDRs to reach the public master endpoint.
  # For a production deployment, restrict this to your CI/CD runner IP range.
  master_authorized_networks_config {
    cidr_blocks {
      cidr_block   = "0.0.0.0/0"
      display_name = "all (lab — restrict in production)"
    }
  }

  # Workload Identity is disabled for simplicity in this lab.
  # Enable it in production for fine-grained pod-level GCP IAM.
  workload_identity_config {
    workload_pool = "${google_project.oran_lab.project_id}.svc.id.goog"
  }

  addons_config {
    # HTTP load balancing is needed for the GKE LoadBalancer Service controller.
    http_load_balancing {
      disabled = false
    }
    # HorizontalPodAutoscaler support.
    horizontal_pod_autoscaling {
      disabled = false
    }
  }

  # Release channel: REGULAR gives stable, tested versions with automatic
  # patch updates. Use STABLE for less frequent updates.
  release_channel {
    channel = "REGULAR"
  }

  depends_on = [
    google_project_service.apis,
    google_compute_subnetwork.oran_lab,
  ]
}

# ----------------------------------------------------------------------------
# 6. GKE Node Pool
# ----------------------------------------------------------------------------
# cos_containerd: Container-Optimized OS with containerd runtime.
# - Minimal OS surface, auto-patched by Google.
# - Supports loading kernel modules (required for SCTP DaemonSet: modprobe sctp).
# - Required for privileged pod / hostNetwork workloads (UPF, SCTP init).

resource "google_container_node_pool" "default" {
  name     = "default-pool"
  project  = google_project.oran_lab.project_id
  location = var.gcp_zone
  cluster  = google_container_cluster.oran_lab.name

  node_count = var.node_count

  node_config {
    machine_type = var.node_machine_type
    disk_size_gb = var.node_disk_size_gb
    disk_type    = "pd-ssd"
    image_type   = "COS_CONTAINERD"

    # Preemptible VMs: ~80% cheaper, can be reclaimed by GCP with 30s notice.
    # Acceptable for a lab environment where NFs can restart.
    preemptible = var.preemptible_nodes

    service_account = google_service_account.ansible.email

    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform",
    ]

    # Labels help kubectl node selectors and visibility.
    labels = {
      env     = "lab"
      project = var.gcp_project_id
    }

    # Shielded nodes: Secure Boot + vTPM. Good practice even for a lab.
    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }
  }

  # Upgrade policy: surge one extra node during upgrades to avoid downtime.
  upgrade_settings {
    max_surge       = 1
    max_unavailable = 0
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  depends_on = [google_container_cluster.oran_lab]
}
