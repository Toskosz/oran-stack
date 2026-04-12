# ============================================================================
# Terraform Import Blocks — idempotent reconciliation of pre-existing resources
# ============================================================================
# Requires Terraform >= 1.5 (enforced in versions.tf as >= 1.7).
# Safe to leave in place permanently: once a resource is in state the import
# block is a no-op on subsequent runs.
#
# Only google_project is imported here. All other resources fall into one of
# two categories that do NOT need import blocks:
#
#   Idempotent by design (provider checks existence before acting, no 409):
#     - google_project_service      (API enablement)
#     - google_service_account
#     - google_project_iam_member
#
#   Depend on the Compute/Container APIs being enabled first — if the API is
#   not yet enabled the import itself errors with 403 before Terraform has had
#   a chance to enable it. Terraform handles the create-or-update cycle for
#   these correctly once the project is in state:
#     - google_compute_network / google_compute_subnetwork
#     - google_compute_router / google_compute_router_nat
#     - google_compute_firewall
#     - google_container_cluster / google_container_node_pool
# ============================================================================

# ----------------------------------------------------------------------------
# GCP Project
# ----------------------------------------------------------------------------
# google_project returns 409 alreadyExists if the project was created outside
# of (or before) this Terraform state. Importing it prevents that error and
# lets Terraform reconcile billing/settings without recreating the project.

import {
  to = google_project.oran_lab
  id = var.gcp_project_id
}
