# Consul's Own Agent Token
#
# Narrow, node-identity-scoped token used by every Consul agent (server
# or client mode alike) purely for self-registration and anti-entropy —
# not for anything workload-related. One shared token per environment
# rather than one per node: a true node-identity token needs an exact,
# known node name, which doesn't exist for autoscaled client instances
# at apply time.
resource "consul_acl_policy" "agent" {
  name = "agent-${var.environment}"
  rules = <<-EOT
    node_prefix "" {
      policy = "write"
    }
    service_prefix "" {
      policy = "write"
    }
  EOT
}

resource "consul_acl_token" "agent" {
  description = "Consul agent token — dc-${var.environment}, server + client nodes"
  policies    = [consul_acl_policy.agent.name]
}

# consul_acl_token deliberately never stores a token's secret in state
# (only the accessor is safe to keep there) — this data source is the
# provider's own documented way to read the secret back out once, right
# after creation.
data "consul_acl_token_secret_id" "agent" {
  accessor_id = consul_acl_token.agent.id
}

resource "google_secret_manager_secret_version" "consul_server_agent_token" {
  secret      = "consul-server-agent-token-${var.environment}"
  secret_data = data.consul_acl_token_secret_id.agent.secret_id
}

resource "google_secret_manager_secret_version" "consul_client_agent_token" {
  secret      = "consul-client-agent-token-${var.environment}"
  secret_data = data.consul_acl_token_secret_id.agent.secret_id # same shared token as the server variant, see comment above
}
