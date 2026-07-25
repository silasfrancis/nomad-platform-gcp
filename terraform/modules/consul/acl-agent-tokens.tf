# Consul's Own Agent Token — Server + Client, Shared Per Environment
#
# Applied via each node's 99-instance.hcl (acl.tokens.agent) at boot.
# One shared token per environment (not per-node) — a true
# node_identity token would need an exact, known node name, which
# doesn't exist for autoscaled client MIGs at apply time. Policy-based
# instead of node_identity is a deliberate tradeoff for that reason.

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
