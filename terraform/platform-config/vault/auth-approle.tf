# Octopus Deploy — AppRole Auth
# Octopus isn't a Nomad task, so it can't use Workload Identity/JWT the
# way tasks do. AppRole is Vault's standard answer for a non-Nomad,
# non-Kubernetes caller that still shouldn't hold a static long-lived
# token: role_id is not secret and can live in Octopus's own variable
# set in the open; secret_id is the actual credential, pushed to Secret
# Manager below for Ansible's octopus role to pick up during bootstrap.

resource "vault_auth_backend" "approle" {
  type = "approle"
}

resource "vault_approle_auth_backend_role" "octopus" {
  backend        = vault_auth_backend.approle.path
  role_name      = "octopus-deploy"
  token_policies = [vault_policy.octopus.name]
  token_ttl      = 3600
  token_max_ttl  = 14400
}

resource "vault_approle_auth_backend_role_secret_id" "octopus" {
  backend   = vault_auth_backend.approle.path
  role_name = vault_approle_auth_backend_role.octopus.role_name
}

resource "google_secret_manager_secret_version" "octopus_approle_role_id" {
  secret      = "octopus-vault-approle-role-id" # container must already exist in bootstrap/
  secret_data = vault_approle_auth_backend_role.octopus.role_id
}

resource "google_secret_manager_secret_version" "octopus_approle_secret_id" {
  secret      = "octopus-vault-approle-secret-id"
  secret_data = vault_approle_auth_backend_role_secret_id.octopus.secret_id
}
