# ============================================================================
# Terraform Outputs — O-RAN Lab GKE Cluster
# ============================================================================

output "project_id" {
  description = "The GCP project ID that was created."
  value       = google_project.oran_lab.project_id
}

output "cluster_name" {
  description = "Name of the GKE cluster."
  value       = google_container_cluster.oran_lab.name
}

output "cluster_location" {
  description = "Zone/region of the GKE cluster."
  value       = google_container_cluster.oran_lab.location
}

output "cluster_endpoint" {
  description = "Public endpoint of the GKE control plane."
  value       = google_container_cluster.oran_lab.endpoint
  sensitive   = true
}

output "cluster_ca_certificate" {
  description = "Base64-encoded cluster CA certificate (used to verify the API server TLS cert)."
  value       = google_container_cluster.oran_lab.master_auth[0].cluster_ca_certificate
  sensitive   = true
}

output "ansible_service_account_email" {
  description = "Email of the service account created for Ansible."
  value       = google_service_account.ansible.email
}

output "get_credentials_command" {
  description = "Run this command to configure kubectl for the new cluster."
  value       = "gcloud container clusters get-credentials ${google_container_cluster.oran_lab.name} --zone ${google_container_cluster.oran_lab.location} --project ${google_project.oran_lab.project_id}"
}
