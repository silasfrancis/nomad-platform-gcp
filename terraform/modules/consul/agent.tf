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
      policy = "read"
    }
  EOT
}

resource "consul_acl_token" "agent" {
  description = "Consul agent token — dc-${var.environment}, server + client nodes"
  policies    = [consul_acl_policy.agent.name]
}

resource "google_secret_manager_secret_version" "consul_server_agent_token" {
  secret      = "consul-server-agent-token-${var.environment}"
  secret_data = consul_acl_token.agent.id
}

resource "google_secret_manager_secret_version" "consul_client_agent_token" {
  secret      = "consul-client-agent-token-${var.environment}"
  secret_data = consul_acl_token.agent.id # same shared token as the server variant, see comment above
}
