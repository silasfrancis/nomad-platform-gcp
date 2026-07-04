output "service_accounts" {
  value = module.service_account.service_accounts
}

output "kms_key_rings" {
  value = module.kms.key_rings
}

output "kms_keys" {
  value = module.kms.kms_keys
}

output "gcs_bucket_names" {
  value = module.gcs_bucket.bucket_names
}

output "gcs_bucket_urls" {
  value = module.gcs_bucket.bucket_urls
}

output "artifact_registry_url" {
  value = module.artifact_registry.artifact_registry_url
}

output "artifact_registry_id" {
  value = module.artifact_registry.artifact_registry_id
}

output "secret_ids" {
  value = module.secrets.secret_ids
}

output "secret_names" {
  value = module.secrets.secret_names
}

output "secrets_by_tier" {
  value = module.secrets.secrets_by_tier
}