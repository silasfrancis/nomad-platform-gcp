# Hands off Octopus's Nomad token to Secret Manager — this is the one
# cross-module dependency in the whole system: mgmt/'s Octopus module
# reads this back to populate the NomadToken deployment variable, so
# this environment's module must be applied at least once before
# mgmt/'s first successful apply.
resource "google_secret_manager_secret_version" "octopus_deploy_token" {
  secret      = "octopus-deploy-token-${var.environment}"
  secret_data = nomad_acl_token.octopus_deploy.secret_id
}

# No secret is written for nomad-sentinel — it authenticates via
# Workload Identity, not a stored token. See acl.tf.
