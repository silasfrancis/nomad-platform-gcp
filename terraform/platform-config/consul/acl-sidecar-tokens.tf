# Per-Service Sidecar Identity Tokens — Connect Mesh Members Only
#
# service_identities auto-generates the correct scoped policy (read
# catalog + write only this service's own sidecar registration) — the
# Consul equivalent of a Kubernetes ServiceAccount. No hand-written
# policy needed per service.
#
# KNOWN SIMPLIFICATION, flagged rather than silently done: Nomad 1.7+
# supports Consul Workload Identity (JWT-based, same shape as the Vault
# integration) which would eliminate needing 14 x 2 static tokens here
# entirely. That would be the more consistent long-term design given
# everything else in this project already avoids standing credentials
# wherever possible — worth revisiting once job specs are actually being
# written, rather than deciding it now speculatively.
#
# Pushed to Secret Manager below under a per-service, per-env naming
# scheme — 28 secret containers, all `scoped` tier, all needing to
# exist in bootstrap/'s default_secrets map before first apply.

resource "consul_acl_token" "sidecar_dev" {
  provider    = consul.dev
  for_each    = local.mesh_services
  description = "Sidecar identity token — ${each.key}, dc-dev"

  service_identities {
    service_name = each.key
  }
}

resource "consul_acl_token" "sidecar_prod" {
  provider    = consul.prod
  for_each    = local.mesh_services
  description = "Sidecar identity token — ${each.key}, dc-prod"

  service_identities {
    service_name = each.key
  }
}

resource "google_secret_manager_secret_version" "sidecar_token_dev" {
  for_each    = local.mesh_services
  secret      = "consul-sidecar-token-${each.key}-dev"
  secret_data = consul_acl_token.sidecar_dev[each.key].id
}

resource "google_secret_manager_secret_version" "sidecar_token_prod" {
  for_each    = local.mesh_services
  secret      = "consul-sidecar-token-${each.key}-prod"
  secret_data = consul_acl_token.sidecar_prod[each.key].id
}
