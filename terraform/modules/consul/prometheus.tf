resource "consul_acl_policy" "prometheus" {
  name = "prometheus-${var.environment}"

  rules = <<-EOT
    service_prefix "" {
      policy = "read"
    }

    node_prefix "" {
      policy = "read"
    }

    agent_prefix "" {
      policy = "read"
    }
  EOT
}

resource "consul_acl_token" "prometheus" {
  description = "Prometheus token — dc-${var.environment}"
  policies    = [consul_acl_policy.prometheus.name]
}

data "consul_acl_token_secret_id" "prometheus" {
  accessor_id = consul_acl_token.prometheus.id
}

resource "vault_kv_secret_v2" "prometheus_token" {
  mount    = "kv"
  name     = "${var.environment}/prometheus/config"
  data_json = jsonencode({
    consul_prometheus_token = "${data.consul_acl_token_secret_id.prometheus.secret_id}"
  })
}