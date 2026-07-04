# bootstrap/outputs.tf
#
# Every value another layer needs from bootstrap must be exported here.
# Other layers read these via:
#   data "terraform_remote_state" "bootstrap" {
#     backend   = "gcs"
#     workspace = "default"
#     config = {
#       bucket = "<tfstate_bucket>"
#       prefix = "bootstrap"
#     }
#   }
# Then reference as: data.terraform_remote_state.bootstrap.outputs.<name>

# ── KMS ───────────────────────────────────────────────────────────────────────

output "vault_unseal_key_id" {
  description = <<-EOT
    Full resource ID of the Vault auto-unseal KMS key.
    Used by the Ansible vault role to write vault.hcl seal stanza:
      seal "gcpckms" {
        key_ring   = "vault-unseal"
        crypto_key = "vault-unseal-key"
      }
  EOT
  value = module.kms["vault-unseal"].key_ids["vault-unseal-key"]
}

output "gcs_storage_key_id" {
  description = <<-EOT
    Full resource ID of the GCS CMEK key.
    Used to apply CMEK to the tfstate bucket after bootstrap (one gcloud command),
    and passed to other layers that create GCS buckets.
  EOT
  value = module.kms["platform-storage"].key_ids["gcs-storage"]
}

output "persistent_disk_key_id" {
  description = <<-EOT
    Full resource ID of the persistent disk CMEK key.
    Used by the compute layer when creating persistent disks for
    Vault data, Octopus data, and Grafana data on the mgmt VM.
  EOT
  value = module.kms["platform-storage"].key_ids["persistent-disk"]
}

output "vault_unseal_keyring_id" {
  description = "Full resource ID of the vault-unseal keyring. Used for keyring-level IAM bindings if needed."
  value       = module.kms["vault-unseal"].keyring_id
}

output "platform_storage_keyring_id" {
  description = "Full resource ID of the platform-storage keyring. Used for keyring-level IAM bindings if needed."
  value       = module.kms["platform-storage"].keyring_id
}

# ── Service accounts ──────────────────────────────────────────────────────────

output "nomad_server_sa_email" {
  description = <<-EOT
    Email of the Nomad server service account.
    Attached to Nomad server VMs in the compute layer.
    Format: nomad-server-sa@<project>.iam.gserviceaccount.com
  EOT
  value = module.service_accounts["nomad-server-sa"].email
}

output "nomad_server_sa_member" {
  description = "IAM member string for nomad-server-sa. Use in google_*_iam_member resources."
  value       = module.service_accounts["nomad-server-sa"].member
}

output "nomad_client_sa_email" {
  description = <<-EOT
    Email of the Nomad client service account.
    Attached to all Nomad client MIG instance templates in the compute layer.
    Format: nomad-client-sa@<project>.iam.gserviceaccount.com
  EOT
  value = module.service_accounts["nomad-client-sa"].email
}

output "nomad_client_sa_member" {
  description = "IAM member string for nomad-client-sa. Use in google_*_iam_member resources."
  value       = module.service_accounts["nomad-client-sa"].member
}

output "management_vm_sa_email" {
  description = <<-EOT
    Email of the management VM service account.
    Attached to the mgmt VM in the compute layer.
    Covers: Vault KMS auto-unseal, GCS backup writes, GitHub runner
    Artifact Registry push, Octopus Deploy, Grafana, internal Traefik.
    Format: management-vm-sa@<project>.iam.gserviceaccount.com
  EOT
  value = module.service_accounts["management-vm-sa"].email
}

output "management_vm_sa_member" {
  description = "IAM member string for management-vm-sa. Use in google_*_iam_member resources."
  value       = module.service_accounts["management-vm-sa"].member
}

# ── GCS buckets ───────────────────────────────────────────────────────────────

output "bucket_names" {
  description = <<-EOT
    Map of bucket key → bucket name for all buckets created by bootstrap.
    Used by backup periodic jobs to construct GCS paths:
      platform-artifacts → gs://platform-artifacts/vault-snapshots/dev/
      ci-cd-artifacts    → gs://ci-cd-artifacts/
  EOT
  value = {
    for key, bucket in google_storage_bucket.buckets :
    key => bucket.name
  }
}

output "platform_artifacts_bucket_name" {
  description = "Name of the platform-artifacts GCS bucket. Convenience output — also available via bucket_names."
  value       = google_storage_bucket.buckets["platform-artifacts"].name
}

output "platform_artifacts_bucket_url" {
  description = "gs:// URL of the platform-artifacts bucket. Use directly in backup job scripts."
  value       = google_storage_bucket.buckets["platform-artifacts"].url
}

output "cicd_artifacts_bucket_name" {
  description = "Name of the ci-cd-artifacts GCS bucket."
  value       = google_storage_bucket.buckets["ci-cd-artifacts"].name
}

output "cicd_artifacts_bucket_url" {
  description = "gs:// URL of the ci-cd-artifacts bucket."
  value       = google_storage_bucket.buckets["ci-cd-artifacts"].url
}

# ── Artifact Registry ─────────────────────────────────────────────────────────

output "artifact_registry_url" {
  description = <<-EOT
    Base URL for the Artifact Registry Docker repository.
    Used by GitHub Actions CI to construct image tags:
      <url>/nomad-sentinel:sha-abc123
      <url>/metrics-api:sha-abc123
      <url>/frontend:sha-abc123
    Format: <region>-docker.pkg.dev/<project>/<repo>
  EOT
  value = "${var.region}-docker.pkg.dev/${var.project_id}/${var.artifact_registry_repo}"
}

output "artifact_registry_id" {
  description = "Full resource ID of the Artifact Registry repository. Used for IAM bindings in other layers."
  value       = google_artifact_registry_repository.platform.id
}