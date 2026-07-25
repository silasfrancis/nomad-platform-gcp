# Nomad Workload Identity — JWT Auth Backends, One Per Environment
# No static token anywhere in this chain — Nomad signs a per-allocation
# JWT, Vault verifies it against Nomad's own JWKS endpoint. See
# providers.tf's Nomad address variables for the per-env JWKS URLs.

resource "vault_jwt_auth_backend" "nomad_dev" {
  path         = "jwt-nomad-dev"
  jwks_url     = "${var.nomad_address_dev}/.well-known/jwks.json"
  bound_issuer = "https://nomad.platform.lefrancis.org"
}

resource "vault_jwt_auth_backend" "nomad_prod" {
  path         = "jwt-nomad-prod"
  jwks_url     = "${var.nomad_address_prod}/.well-known/jwks.json"
  bound_issuer = "https://nomad.platform.lefrancis.org"
}

# Per-Consumer Roles — One Per Service In locals.vault_consumers, Per Env.
# NOT looped across a combined dev+prod list, since the backend itself
# differs per environment (two separate JWT auth mounts above).

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
  token_policies = ["${each.key}-policy"]
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
  token_policies = ["${each.key}-policy"]
  token_ttl      = 3600
}
