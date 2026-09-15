# Nomad Workload Identity — JWT Auth Backends, One Per Environment

# Nomad signs a per-allocation JWT at placement time, and Vault verifies it
# directly against Nomad's own JWKS endpoint.

resource "vault_jwt_auth_backend" "nomad" {
  for_each = var.nomad_provisioned ? toset(var.nomad_environments) : toset([])

  path     = "jwt-nomad-${each.key}"
  jwks_url = "${var.nomad_addresses[each.key]}/.well-known/jwks.json"
  # no jwks_ca_pem as var.nomad_address_dev already routes through the traefik internal instance
  # which already handles the trust (rootCAs) for the self signed certificates
}

# Per-Consumer Roles — One Per Service In locals.vault_consumers, Per
# Environment. Each role's policy reference matches the per-environment
# policy name from policies.tf, so a dev role can never resolve to a
# policy that also grants prod access.

locals {
  vault_consumer_roles = {
    for item in flatten([
      for environment in var.nomad_environments : [
        for consumer_name, consumer in local.vault_consumers : {
          key         = "${environment}-${consumer_name}"
          environment = environment
          name        = consumer_name
          namespace   = consumer.namespace
        }
      ]
    ]) : item.key => item
  }
}

resource "vault_jwt_auth_backend_role" "consumer" {
  for_each = var.nomad_provisioned ? local.vault_consumer_roles : {}

  backend   = vault_jwt_auth_backend.nomad[each.value.environment].path
  role_name = each.value.name
  role_type = "jwt"
  bound_audiences = ["vault.io"]
  user_claim = "nomad_job_id"

  bound_claims = {
    nomad_namespace = each.value.namespace
    nomad_job_id    = each.value.name
  }

  token_policies = [
    "${each.value.name}-${each.value.environment}-policy"
  ]

  token_ttl = 3600
}

