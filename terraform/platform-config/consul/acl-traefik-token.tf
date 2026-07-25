# Traefik — Catalog Read Only
#
# Flag 5 (resolved this session): the KV-read grant from the original
# plan is dropped. The actual traefik role uses Consul's catalog
# provider, not KV, for routing — there's no KV-based routing design in
# this project to justify the grant.

resource "consul_acl_policy" "traefik_dev" {
  provider = consul.dev
  name     = "traefik-dev"
  rules    = <<-EOT
    service_prefix "" {
      policy = "read"
    }
    node_prefix "" {
      policy = "read"
    }
  EOT
}

resource "consul_acl_token" "traefik_dev" {
  provider    = consul.dev
  description = "Traefik catalog-provider token — dc-dev"
  policies    = [consul_acl_policy.traefik_dev.name]
}

resource "consul_acl_policy" "traefik_prod" {
  provider = consul.prod
  name     = "traefik-prod"
  rules    = <<-EOT
    service_prefix "" {
      policy = "read"
    }
    node_prefix "" {
      policy = "read"
    }
  EOT
}

resource "consul_acl_token" "traefik_prod" {
  provider    = consul.prod
  description = "Traefik catalog-provider token — dc-prod"
  policies    = [consul_acl_policy.traefik_prod.name]
}

resource "google_secret_manager_secret_version" "traefik_token_dev" {
  secret      = "traefik-consul-token-dev"
  secret_data = consul_acl_token.traefik_dev.id
}

resource "google_secret_manager_secret_version" "traefik_token_prod" {
  secret      = "traefik-consul-token-prod"
  secret_data = consul_acl_token.traefik_prod.id
}
