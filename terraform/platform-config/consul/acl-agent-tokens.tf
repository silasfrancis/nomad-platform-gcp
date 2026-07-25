# Consul's Own Agent Token — Server + Client, Per Environment
#
# Applied via each node's 99-instance.hcl (acl.tokens.agent) at boot,
# per Consul's own recommendation — reloads from the config file on
# restart, no separate CLI call needed. Narrow node-identity scope:
# self-registration + anti-entropy only, same shape for server or
# client mode.
#
# Cardinality note: this is ONE shared token per environment (not
# per-node). A true consul_acl_token{ node_identity{} } would need an
# exact, known node name — fine for the single static nomad-{env}-server
# VM, but client nodes are autoscaled MIGs whose instance names don't
# exist at apply time. Using a policy-based token instead of
# node_identity is a deliberate tradeoff for that reason, not an
# oversight — it's broader than ideal but the only workable shape given
# autoscaling.

resource "consul_acl_policy" "agent_dev" {
  provider = consul.dev
  name     = "agent-dev"
  rules    = <<-EOT
    node_prefix "" {
      policy = "write"
    }
    service_prefix "" {
      policy = "read"
    }
  EOT
}

resource "consul_acl_token" "agent_dev" {
  provider    = consul.dev
  description = "Consul agent token — dc-dev, server + client nodes"
  policies    = [consul_acl_policy.agent_dev.name]
}

resource "consul_acl_policy" "agent_prod" {
  provider = consul.prod
  name     = "agent-prod"
  rules    = <<-EOT
    node_prefix "" {
      policy = "write"
    }
    service_prefix "" {
      policy = "read"
    }
  EOT
}

resource "consul_acl_token" "agent_prod" {
  provider    = consul.prod
  description = "Consul agent token — dc-prod, server + client nodes"
  policies    = [consul_acl_policy.agent_prod.name]
}
