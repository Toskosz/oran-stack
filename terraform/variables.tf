# ============================================================================
# Terraform Variables for the O-RAN Lab GKE Deployment
# ============================================================================
# Required values (no defaults) must be supplied via:
#   - ansible group_vars/all.yml  (when driven by Ansible)
#   - terraform.tfvars            (when running Terraform directly)
#   - TF_VAR_* environment variables
# ============================================================================

# ----------------------------------------------------------------------------
# GCP Project
# ----------------------------------------------------------------------------

variable "gcp_billing_account" {
  description = "GCP Billing Account ID to attach to the new project (format: XXXXXX-XXXXXX-XXXXXX). See TODO.md."
  type        = string
}

variable "gcp_project_id" {
  description = "Globally unique GCP project ID to create (e.g. 'oran-lab-abc123'). Must be 6-30 chars, lowercase letters/digits/hyphens."
  type        = string
}

variable "gcp_project_name" {
  description = "Human-readable display name for the GCP project."
  type        = string
  default     = "O-RAN Lab"
}

# ----------------------------------------------------------------------------
# Region / Zone
# ----------------------------------------------------------------------------

variable "gcp_region" {
  description = "GCP region for the GKE cluster and associated resources."
  type        = string
  default     = "us-central1"
}

variable "gcp_zone" {
  description = "Primary GCP zone for the node pool."
  type        = string
  default     = "us-central1-a"
}

# ----------------------------------------------------------------------------
# GKE Cluster
# ----------------------------------------------------------------------------

variable "cluster_name" {
  description = "Name of the GKE cluster."
  type        = string
  default     = "oran-lab"
}

variable "kubernetes_version" {
  description = "Minimum Kubernetes version for GKE. Must be >= 1.28 for SCTP Service support."
  type        = string
  default     = "1.30"
}

# ----------------------------------------------------------------------------
# Node Pool
# ----------------------------------------------------------------------------

variable "node_machine_type" {
  description = "GCE machine type for the default node pool. n2-standard-4 gives 4 vCPU / 16 GB."
  type        = string
  default     = "n2-standard-4"
}

variable "node_count" {
  description = "Number of nodes in the default node pool."
  type        = number
  default     = 2
}

variable "preemptible_nodes" {
  description = "Use preemptible (spot) VMs for ~80% cost reduction. Fine for a lab; not for production."
  type        = bool
  default     = true
}

variable "node_disk_size_gb" {
  description = "Boot disk size per node in GB."
  type        = number
  default     = 100
}

# ----------------------------------------------------------------------------
# Networking
# ----------------------------------------------------------------------------

variable "vpc_name" {
  description = "Name of the VPC network to create."
  type        = string
  default     = "oran-lab-vpc"
}

variable "subnet_cidr" {
  description = "Primary CIDR for the GKE subnet."
  type        = string
  default     = "10.0.0.0/20"
}

variable "pods_cidr" {
  description = "Secondary CIDR range used for Pod IPs (VPC-native alias-IP mode)."
  type        = string
  default     = "10.4.0.0/14"
}

variable "services_cidr" {
  description = "Secondary CIDR range used for Service (ClusterIP) IPs."
  type        = string
  default     = "10.8.0.0/20"
}

variable "master_cidr" {
  description = "Private /28 CIDR for the GKE control plane. Must not overlap with node/pod/service CIDRs."
  type        = string
  default     = "172.16.0.0/28"
}
