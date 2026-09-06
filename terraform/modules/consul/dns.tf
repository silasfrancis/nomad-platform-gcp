resource "consul_acl_policy" "dns" {
  name = "dns-${var.environment}"
  rules = <<-EOT
    node_prefix "" {
      policy = "read"
    }
    service_prefix "" {
      policy = "read"
    }
    query_prefix "" {
      policy = "read"
    }
  EOT
}

resource "consul_acl_token" "dns" {
  description = "Consul DNS default token — dc-${var.environment}"
  policies    = [consul_acl_policy.dns.name]
}

data "consul_acl_token_secret_id" "dns" {
  accessor_id = consul_acl_token.dns.id
}

resource "google_secret_manager_secret_version" "consul_dns_token" {
  secret      = "consul-dns-token-${var.environment}"
  secret_data = data.consul_acl_token_secret_id.dns.secret_id
}