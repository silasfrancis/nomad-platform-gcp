# Nomad Workload Identity — JWT Auth Backends, One Per Environment
#
# No static token anywhere in this chain: Nomad signs a per-allocation
# JWT at placement time, and Vault verifies it directly against Nomad's
# own JWKS endpoint.
resource "vault_jwt_auth_backend" "nomad_dev" {
  path        = "jwt-nomad-dev"
  jwks_url    = "${var.nomad_address_dev}/.well-known/jwks.json"
  jwks_ca_pem = data.google_secret_manager_secret_version.ca_cert_dev.secret_data
}

resource "vault_jwt_auth_backend" "nomad_prod" {
  path        = "jwt-nomad-prod"
  jwks_url    = "${var.nomad_address_prod}/.well-known/jwks.json"
  jwks_ca_pem = data.google_secret_manager_secret_version.ca_cert_prod.secret_data
}

# Vault's outbound call to Nomad's JWKS endpoint needs to trust
# whichever CA signed Nomad's own server certificate — this is Nomad's
# environment CA, not Vault's own certificate, since Vault is the
# caller here rather than the thing being connected to.
data "google_secret_manager_secret_version" "ca_cert_dev" {
  secret = "ca-cert-dev"
}

data "google_secret_manager_secret_version" "ca_cert_prod" {
  secret = "ca-cert-prod"
}

# Per-Consumer Roles — One Per Service In locals.vault_consumers, Per
# Environment. Each role's policy reference matches the per-environment
# policy name from policies.tf, so a dev role can never resolve to a
# policy that also grants prod access.
resource "vault_jwt_auth_backend_role" "consumer_dev" {
  for_each = local.vault_consumers

  backend         = vault_jwt_auth_backend.nomad_dev.path
  role_name       = each.key
  role_type       = "jwt"
  bound_audiences = ["vault.io"]
  user_claim      = "nomad_job_id"
  bound_claims = {
    nomad_namespace = each.value.namespace
    nomad_job_id    = each.key
  }
  token_policies = ["${each.key}-dev-policy"]
  token_ttl      = 3600
}

resource "vault_jwt_auth_backend_role" "consumer_prod" {
  for_each = local.vault_consumers

  backend         = vault_jwt_auth_backend.nomad_prod.path
  role_name       = each.key
  role_type       = "jwt"
  bound_audiences = ["vault.io"]
  user_claim      = "nomad_job_id"
  bound_claims = {
    nomad_namespace = each.value.namespace
    nomad_job_id    = each.key
  }
  token_policies = ["${each.key}-prod-policy"]
  token_ttl      = 3600
}
