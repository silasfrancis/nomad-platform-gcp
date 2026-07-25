# Hands Off Both Tokens To Secret Manager — This Is The Cross-Folder
# Bridge To vault/ (which reads nomad-sentinel-token-{env} back in to
# populate kv/data/{env}/ai-agent/config) and to Ansible's octopus role
# (which reads octopus-deploy-token-{env} into Octopus's own variable
# set, since Octopus has no native Vault integration in this
# architecture beyond the AppRole built in vault/auth-approle.tf for its
# OWN secret reads — this token is Octopus's outbound credential TO
# Nomad, a different direction, hence the separate handoff here).

resource "google_secret_manager_secret_version" "nomad_sentinel_token_dev" {
  secret      = "nomad-sentinel-token-dev"
  secret_data = nomad_acl_token.nomad_sentinel_dev.secret_id
}

resource "google_secret_manager_secret_version" "nomad_sentinel_token_prod" {
  secret      = "nomad-sentinel-token-prod"
  secret_data = nomad_acl_token.nomad_sentinel_prod.secret_id
}

resource "google_secret_manager_secret_version" "octopus_deploy_token_dev" {
  secret      = "octopus-deploy-token-dev"
  secret_data = nomad_acl_token.octopus_dev.secret_id
}

resource "google_secret_manager_secret_version" "octopus_deploy_token_prod" {
  secret      = "octopus-deploy-token-prod"
  secret_data = nomad_acl_token.octopus_prod.secret_id
}
