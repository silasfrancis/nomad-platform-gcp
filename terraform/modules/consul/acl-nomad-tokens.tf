# Nomad's Own Consul Token — Server Variant
#
# Separate credential from the agent token. Nomad is its own Consul API
# caller: registers nomad-server/nomad-client services, does auto-join
# discovery, and (server-mode only) manages Connect config entries —
# hence the extra acl/mesh write grants the client variant doesn't get.
resource "consul_acl_policy" "nomad_server" {
  name = "nomad-server-${var.environment}"
  rules = <<-EOT
    agent_prefix "" {
      policy = "read"
    }
    node_prefix "" {
      policy = "write"
    }
    service_prefix "" {
      policy = "write"
    }
    acl  = "write"
    mesh = "write"
  EOT
}

resource "consul_acl_token" "nomad_server" {
  description = "Nomad server's own Consul token — dc-${var.environment}"
  policies    = [consul_acl_policy.nomad_server.name]
}

# Nomad's Own Consul Token — Client Variant
#
# acl:write here is what lets Nomad clients request Consul Service
# Identity (SI) tokens automatically for Connect sidecars at allocation
# time (Nomad 1.7+ Workload Identity) — this is what makes the
# now-removed static per-service sidecar token block unnecessary.
resource "consul_acl_policy" "nomad_client" {
  name = "nomad-client-${var.environment}"
  rules = <<-EOT
    agent_prefix "" {
      policy = "read"
    }
    node_prefix "" {
      policy = "write"
    }
    service_prefix "" {
      policy = "write"
    }
    acl = "write"
  EOT
}

resource "consul_acl_token" "nomad_client" {
  description = "Nomad client's own Consul token — dc-${var.environment}"
  policies    = [consul_acl_policy.nomad_client.name]
}
