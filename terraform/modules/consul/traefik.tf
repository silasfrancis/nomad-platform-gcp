# Traefik — Catalog Read Only
#
# Traefik's catalog provider only ever reads service tags to build
# routing rules; it never reads or writes Consul's KV store, so no
# KV-related grant is included here.
resource "consul_acl_policy" "traefik" {
  name = "traefik-${var.environment}"
  rules = <<-EOT
    service_prefix "" {
      policy = "read"
    }
    node_prefix "" {
      policy = "read"
    }
  EOT
}

resource "consul_acl_token" "traefik" {
  description = "Traefik catalog-provider token — dc-${var.environment}"
  policies    = [consul_acl_policy.traefik.name]
}

data "consul_acl_token_secret_id" "traefik" {
  accessor_id = consul_acl_token.traefik.id
}

resource "google_secret_manager_secret_version" "traefik_token" {
  secret      = "consul-traefik-token-${var.environment}"
  secret_data = data.consul_acl_token_secret_id.traefik.secret_id
}
