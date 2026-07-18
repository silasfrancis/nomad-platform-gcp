output "secret_ids" {
  description = "Map of secret name to its full Secret Manager resource ID."
  value       = { for k, v in google_secret_manager_secret.secret : k => v.id }
}

output "secret_names" {
  description = "Map of secret name to its short secret_id (same as the map key, exposed for convenience in Ansible/CI templating)."
  value       = { for k, v in google_secret_manager_secret.secret : k => v.secret_id }
}

output "secrets_by_tier" {
  description = "Secret names grouped by tier label, useful for scripting (e.g. verifying which secrets a given SA should have access to)."
  value = {
    for tier in ["root", "operator", "mgmt", "scoped"] : tier => [
      for name, secret in local.secrets : name
      if lookup(secret.labels, "tier", "scoped") == tier
    ]
  }
}