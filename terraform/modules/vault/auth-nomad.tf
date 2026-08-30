# Nomad Workload Identity — JWT Auth Backends, One Per Environment

# Nomad signs a per-allocation JWT at placement time, and Vault verifies it
# directly against Nomad's own JWKS endpoint.
resource "vault_jwt_auth_backend" "nomad_dev" {
  count = var.nomad_provisioned ? 1 : 0
  path        = "jwt-nomad-dev"
  jwks_url    = "${var.nomad_address_dev}/.well-known/jwks.json"
  # no jwks_ca_pem as var.nomad_address_dev already routes through the traefik internal instance
  # which already handles the trust (rootCAs) for the self signed certificates
}

# resource "vault_jwt_auth_backend" "nomad_prod" {
#   count = var.nomad_provisioned ? 1 : 0
#   path        = "jwt-nomad-prod"
#   jwks_url    = "${var.nomad_address_prod}/.well-known/jwks.json"
# }

# Per-Consumer Roles — One Per Service In locals.vault_consumers, Per
# Environment. Each role's policy reference matches the per-environment
# policy name from policies.tf, so a dev role can never resolve to a
# policy that also grants prod access.
resource "vault_jwt_auth_backend_role" "consumer_dev" {
  for_each = var.nomad_provisioned ? local.vault_consumers : {}

  backend         = vault_jwt_auth_backend.nomad_dev[0].path
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

# resource "vault_jwt_auth_backend_role" "consumer_prod" {
#   for_each = var.nomad_provisioned ? local.vault_consumers : {}

#   backend         = vault_jwt_auth_backend.nomad_prod[0].path
#   role_name       = each.key
#   role_type       = "jwt"
#   bound_audiences = ["vault.io"]
#   user_claim      = "nomad_job_id"
#   bound_claims = {
#     nomad_namespace = each.value.namespace
#     nomad_job_id    = each.key
#   }
#   token_policies = ["${each.key}-prod-policy"]
#   token_ttl      = 3600
# }
