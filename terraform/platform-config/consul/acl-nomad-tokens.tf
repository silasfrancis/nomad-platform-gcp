# Nomad's Own Consul Token — Server Variant
#
# Separate credential from the agent token above. Nomad is its own
# Consul API caller: registers nomad-server/nomad-client services, does
# auto-join discovery, and (server-mode only) manages Connect config
# entries — hence the extra acl/mesh write grants the client variant
# below doesn't get.
resource "consul_acl_policy" "nomad_server_dev" {
  provider = consul.dev
  name     = "nomad-server-dev"
  rules    = <<-EOT
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

resource "consul_acl_token" "nomad_server_dev" {
  provider    = consul.dev
  description = "Nomad server's own Consul token — dc-dev"
  policies    = [consul_acl_policy.nomad_server_dev.name]
}

resource "consul_acl_policy" "nomad_server_prod" {
  provider = consul.prod
  name     = "nomad-server-prod"
  rules    = <<-EOT
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

resource "consul_acl_token" "nomad_server_prod" {
  provider    = consul.prod
  description = "Nomad server's own Consul token — dc-prod"
  policies    = [consul_acl_policy.nomad_server_prod.name]
}

# Nomad's Own Consul Token — Client Variant (Narrower — No acl/mesh Write)
resource "consul_acl_policy" "nomad_client_dev" {
  provider = consul.dev
  name     = "nomad-client-dev"
  rules    = <<-EOT
    agent_prefix "" {
      policy = "read"
    }
    node_prefix "" {
      policy = "write"
    }
    service_prefix "" {
      policy = "write"
    }
  EOT
}

resource "consul_acl_token" "nomad_client_dev" {
  provider    = consul.dev
  description = "Nomad client's own Consul token — dc-dev"
  policies    = [consul_acl_policy.nomad_client_dev.name]
}

resource "consul_acl_policy" "nomad_client_prod" {
  provider = consul.prod
  name     = "nomad-client-prod"
  rules    = <<-EOT
    agent_prefix "" {
      policy = "read"
    }
    node_prefix "" {
      policy = "write"
    }
    service_prefix "" {
      policy = "write"
    }
  EOT
}

resource "consul_acl_token" "nomad_client_prod" {
  provider    = consul.prod
  description = "Nomad client's own Consul token — dc-prod"
  policies    = [consul_acl_policy.nomad_client_prod.name]
}
