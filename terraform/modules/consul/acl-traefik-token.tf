# Traefik — Catalog Read Only
#
# The actual traefik role uses Consul's catalog provider, not KV, for
# routing — no KV-read grant is included.
#
# Secret name corrected to match bootstrap/'s actual naming:
# consul-traefik-token-{env}, not traefik-consul-token-{env} (the
# reversed name used in an earlier draft this session).

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

resource "google_secret_manager_secret_version" "traefik_token" {
  secret      = "consul-traefik-token-${var.environment}"
  secret_data = consul_acl_token.traefik.id
}
