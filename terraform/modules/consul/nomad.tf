# Nomad's Own Consul Tokens
#
# Separate from the plain agent token above — Nomad is its own Consul
# API caller, registering nomad-server/nomad-client services and
# performing auto-join discovery. The server variant additionally
# manages Connect configuration entries, hence the extra acl/mesh
# grants the client variant doesn't need.
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

# See the comment on data.consul_acl_token_secret_id.agent in agent.tf —
# same reasoning applies to every token in this module.
data "consul_acl_token_secret_id" "nomad_server" {
  accessor_id = consul_acl_token.nomad_server.accessor_id
}

resource "google_secret_manager_secret_version" "nomad_server_consul_token" {
  secret      = "nomad-server-consul-token-${var.environment}"
  secret_data = data.consul_acl_token_secret_id.nomad_server.secret_id
}

# acl:write here is what lets Nomad clients request Consul Service
# Identity tokens automatically for Connect sidecars at allocation
# time, instead of any static per-service token being pre-created.
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

data "consul_acl_token_secret_id" "nomad_client" {
  accessor_id = consul_acl_token.nomad_client.accessor_id
}

resource "google_secret_manager_secret_version" "nomad_client_consul_token" {
  secret      = "nomad-client-consul-token-${var.environment}"
  secret_data = data.consul_acl_token_secret_id.nomad_client.secret_id
}
