# Hands Off Both Tokens To Secret Manager — nomad-sentinel-token is no
# longer read by vault/ (dropped from ai_agent_config), kept here as an
# interim value in case the static-token fallback is needed; may become
# dead weight once Workload Identity is confirmed for Nomad's own API.
# octopus-deploy-token IS actively read, by mgmt/octopus.

resource "google_secret_manager_secret_version" "nomad_sentinel_token" {
  secret      = "nomad-sentinel-token-${var.environment}"
  secret_data = nomad_acl_token.nomad_sentinel.secret_id
}

resource "google_secret_manager_secret_version" "octopus_deploy_token" {
  secret      = "octopus-deploy-token-${var.environment}"
  secret_data = nomad_acl_token.octopus_deploy.secret_id
}
