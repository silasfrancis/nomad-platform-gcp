# bootstrap/outputs.tf
#
# These outputs are read by network/, compute/, and platform-config/
# via terraform_remote_state. Any value another layer needs from bootstrap
# must be exported here.

# ── KMS key IDs ───────────────────────────────────────────────────────────────

output "vault_unseal_key_id" {
  description = "Full resource ID of the Vault auto-unseal KMS key. Used by Ansible vault role to write vault.hcl."
  value       = module.kms_vault_unseal.key_ids["vault-unseal-key"]
}

output "gcs_storage_key_id" {
  description = "Full resource ID of the GCS CMEK key. Applied to tfstate bucket after bootstrap and to platform-artifacts bucket."
  value       = module.kms_platform_storage.key_ids["gcs-storage"]
}

output "persistent_disk_key_id" {
  description = "Full resource ID of the persistent disk CMEK key. Used by compute/ layer when creating PDs for Vault data, Octopus data, Grafana data."
  value       = module.kms_platform_storage.key_ids["persistent-disk"]
}

# ── Service account emails ─────────────────────────────────────────────────────

output "nomad_server_sa_email" {
  description = "Email of the Nomad server service account. Attached to nomad server VMs in compute/."
  value       = module.sa_nomad_server.email
}

output "nomad_client_sa_email" {
  description = "Email of the Nomad client service account. Attached to all client MIG instance templates in compute/."
  value       = module.sa_nomad_client.email
}

output "vault_sa_email" {
  description = "Email of the Vault service account. Attached to mgmt VM in compute/. Also used by GitHub runner on same VM."
  value       = module.sa_vault.email
}

# ── Bucket names ───────────────────────────────────────────────────────────────

output "artifacts_bucket_name" {
  description = "Name of the platform-artifacts GCS bucket. Used by backup periodic jobs to construct GCS paths."
  value       = google_storage_bucket.platform_artifacts.name
}

# ── Artifact Registry ──────────────────────────────────────────────────────────

output "artifact_registry_url" {
  description = "Base URL for the Artifact Registry Docker repository. Used by CI to construct image tags."
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/${var.artifact_registry_repo}"
}
