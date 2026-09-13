locals {
  cidr = var.subnet_cidrs

  rules = {
    "iap-ssh" = {
      description         = "Allow SSH from Google IAP tunnel to all subnets"
      direction           = "INGRESS"
      priority            = 1000
      source_ranges       = ["35.235.240.0/20"]
      destination_ranges = [
        local.cidr["subnet-mgmt"],
        local.cidr["subnet-dev-private"],
        local.cidr["subnet-prod-private"],
        local.cidr["subnet-dev-public"],
        local.cidr["subnet-prod-public"],
      ]
      allow = [{ protocol = "tcp", ports = ["22"] }]
      deny  = []
    }

    "iap-traefik-internal" = {
      description         = "Allow IAP tunnel access to traefik-internal's 5 HTTPS entrypoints (mgmt 8443, dev-internal 8444, prod-internal 8445, Grafana/falco-webhook 8446-8447) for scripts/open-tunnel.sh"
      direction           = "INGRESS"
      priority            = 1000
      source_ranges       = ["35.235.240.0/20"]
      destination_ranges  = [local.cidr["subnet-mgmt"]]
      allow               = [{ protocol = "tcp", ports = ["8443-8447"] }]
      deny                = []
    }

    "health-check-nomad-clients" = {
      description         = "Allow GCP health checker ranges to probe Nomad client API for MIG instance health"
      direction           = "INGRESS"
      priority            = 1000
      source_ranges       = ["35.191.0.0/16", "130.211.0.0/22"]
      destination_ranges  = [local.cidr["subnet-dev-private"], local.cidr["subnet-prod-private"]]
      allow               = [{ protocol = "tcp", ports = ["4646"] }]
      deny                = []
    }

    "deny-dev-to-prod" = {
      description         = "Explicitly deny all traffic from dev-private to prod-private to enforce environment isolation"
      direction           = "INGRESS"
      priority            = 900
      source_ranges       = [local.cidr["subnet-dev-private"]]
      destination_ranges  = [local.cidr["subnet-prod-private"]]
      allow               = []
      deny                = [{ protocol = "all", ports = [] }]
    }

    "deny-prod-to-dev" = {
      description         = "Explicitly deny all traffic from prod-private to dev-private to enforce environment isolation"
      direction           = "INGRESS"
      priority            = 900
      source_ranges       = [local.cidr["subnet-prod-private"]]
      destination_ranges  = [local.cidr["subnet-dev-private"]]
      allow               = []
      deny                = [{ protocol = "all", ports = [] }]
    }

    "nomad-internal" = {
      description = "Allow Nomad RPC/Serf traffic between servers and clients within and across dev/prod private subnets"
      direction = "INGRESS"
      priority  = 1000
      source_ranges = [
        local.cidr["subnet-dev-private"],
        local.cidr["subnet-prod-private"],
      ]
      destination_ranges = [
        local.cidr["subnet-dev-private"],
        local.cidr["subnet-prod-private"],
      ]
      allow = [
        { protocol = "tcp", ports = ["4646", "4647", "4648"] },
        { protocol = "udp", ports = ["4648"] },
      ]
      deny = []
    }

    "consul-internal" = {
      description = "Allow Consul server RPC, Serf LAN gossip, and gRPC API traffic within and across dev/prod private subnets"
      direction = "INGRESS"
      priority  = 1000
      source_ranges = [
        local.cidr["subnet-dev-private"],
        local.cidr["subnet-prod-private"],
      ]
      destination_ranges = [
        local.cidr["subnet-dev-private"],
        local.cidr["subnet-prod-private"],
      ]
      allow = [
        { protocol = "tcp", ports = ["8300", "8301", "8302", "8501"] },
        { protocol = "udp", ports = ["8301", "8302"] },
      ]
      deny = []
    }

    "nomad-clients-to-clients" = {
      description         = "Allow Nomad clients in dev/prod private subnets to reach upstream services (static ports) in the cluster"
      direction           = "INGRESS"
      priority            = 1000
      source_ranges       = [local.cidr["subnet-dev-private"], local.cidr["subnet-prod-private"]]
      destination_ranges  = [local.cidr["subnet-dev-private"], local.cidr["subnet-prod-private"]]
            allow = [
        {
          protocol = "tcp"
          ports =  [
              "5432", # Postgres
              "9090", # Prometheus
            ]
        },
      ]
      deny                = []
    }

    "nomad-clients-to-traefik-internal" = {
      description         = "Allow Nomad clients in dev/prod private subnets to reach Vault via traefik-internal's mgmt entrypoint on 8443"
      direction           = "INGRESS"
      priority            = 1000
      source_ranges       = [local.cidr["subnet-dev-private"], local.cidr["subnet-prod-private"]]
      destination_ranges  = [local.cidr["subnet-mgmt"]]
      allow               = [{ protocol = "tcp", ports = ["8443"] }] # vault entrypoint on traefik internal
      deny                = []
    }

    "consul-connect-sidecars" = {
      description = "Allow Consul Connect sidecar/Envoy proxy traffic across dev/prod private subnets over Nomad's dynamic port range"
      direction = "INGRESS"
      priority  = 1000
      source_ranges = [
        local.cidr["subnet-dev-private"],
        local.cidr["subnet-prod-private"],
      ]
      destination_ranges = [
        local.cidr["subnet-dev-private"],
        local.cidr["subnet-prod-private"],
      ]
      allow = [{ protocol = "tcp", ports = ["20000-32000"] }] # Nomad dynamic port alloc range
      deny  = []
    }

    "consul-catalog-dev-public" = {
      description         = "Allow dev-public subnet (public-facing Traefik) to query Consul catalog API in dev-private"
      direction           = "INGRESS"
      priority            = 1000
      source_ranges       = [local.cidr["subnet-dev-public"]]
      destination_ranges  = [local.cidr["subnet-dev-private"]]
      allow               = [{ protocol = "tcp", ports = ["8501"] }]
      deny                = []
    }

    "consul-catalog-prod-public" = {
      description         = "Allow prod-public subnet (public-facing Traefik) to query Consul catalog API in prod-private"
      direction           = "INGRESS"
      priority            = 1000
      source_ranges       = [local.cidr["subnet-prod-public"]]
      destination_ranges  = [local.cidr["subnet-prod-private"]]
      allow               = [{ protocol = "tcp", ports = ["8501"] }]
      deny                = []
    }

    "traefik-public" = {
      description         = "Allow public internet HTTP/HTTPS traffic to public-facing Traefik instances in dev/prod public subnets"
      direction           = "INGRESS"
      priority            = 1000
      source_ranges       = ["0.0.0.0/0"]
      destination_ranges  = [local.cidr["subnet-dev-public"], local.cidr["subnet-prod-public"]]
      allow               = [{ protocol = "tcp", ports = ["80", "443"] }]
      deny                = []
    }

    "traefik-backend-dev" = {
      description         = "Allow public-facing Traefik in dev-public to reach Nomad-scheduled backend services in dev-private over dynamic ports"
      direction           = "INGRESS"
      priority            = 1000
      source_ranges       = [local.cidr["subnet-dev-public"]]
      destination_ranges  = [local.cidr["subnet-dev-private"]]
      allow               = [{ protocol = "tcp", ports = ["20000-32000"] }] # Nomad dynamic port alloc range
      deny                = []
    }

    "traefik-backend-prod" = {
      description         = "Allow public-facing Traefik in prod-public to reach Nomad-scheduled backend services in prod-private over dynamic ports"
      direction           = "INGRESS"
      priority            = 1000
      source_ranges       = [local.cidr["subnet-prod-public"]]
      destination_ranges  = [local.cidr["subnet-prod-private"]]
      allow               = [{ protocol = "tcp", ports = ["20000-32000"] }] # Nomad dynamic port alloc range
      deny                = []
    }

    "traefik-internal-nomad" = {
      description         = "Allow Traefik internal to reach Nomad-scheduled backend services in over dynamic ports + static ports (prom, postgres, loki and nomad sentinel)"
      direction           = "INGRESS"
      priority            = 1000
      source_ranges       = [local.cidr["subnet-mgmt"]]
      destination_ranges = [
        local.cidr["subnet-dev-private"],
        local.cidr["subnet-prod-private"],
      ]
      allow = [
        {
          protocol = "tcp"
          ports =  [
              "5432", # Postgres
              "9090", # Prometheus
              "20000-32000",   # Nomad dynamic allocation ports
            ]
        },
      ]
      deny                = []
    }

    "traefik-internal-nomad-consul-servers" = {
      description         = "Allow Traefik internal to reach Nomad and consul servers/UI for internal admin use"
      direction           = "INGRESS"
      priority            = 1000
      source_ranges       = [local.cidr["subnet-mgmt"]]
      destination_ranges = [
        local.cidr["subnet-dev-private"],
        local.cidr["subnet-prod-private"],
      ]
      allow = [
        {
          protocol = "tcp"
          ports =  [
              "4646", # Nomad
              "8501", # Consul
            ]
        },
      ]
      deny                = []
    }


    "traefik-internal-mgmt" = {
      description         = "Allow traefik-internal and mgmt-vm to reach each other on Vault/Octopus/Grafana ports, Traefik's own entrypoints, and Vault's Postgres TCP passthrough"
      direction           = "INGRESS"
      priority            = 1000
      source_ranges       = [local.cidr["subnet-mgmt"]]
      destination_ranges  = [local.cidr["subnet-mgmt"]]
      allow = [
        { protocol = "tcp", ports = ["8200", "8080", "3000", "8443-8447", "15432", "15433"] },
      ]
      deny = []
    }

    "prometheus-scrape" = {
      description         = "Allow Prometheus to scrape Consul, Nomad, node-exporter, and Nomad-scheduled service targets directly"
      direction           = "INGRESS"
      priority            = 1000
      source_ranges = [
        local.cidr["subnet-dev-private"],
        local.cidr["subnet-prod-private"],
      ]
      destination_ranges  = [
        local.cidr["subnet-dev-private"],
        local.cidr["subnet-prod-private"],
      ]
      allow = [
        {
          protocol = "tcp"
          ports =  [
              "8501",          # consul api
              "4646",          # nomad api
              "9100",          # node-exporter
              "20000-32000",   # Nomad dynamic allocation ports
            ]
        },
      ]
      deny = []
    }

    "prometheus-to-traefik-internal" = {
      description = "Allow Prometheus in dev/prod private to scrape traefik-internal's own metrics endpoints on mgmt"
      direction = "INGRESS"
      priority  = 1000

      source_ranges = [
        local.cidr["subnet-dev-private"],
        local.cidr["subnet-prod-private"],
      ]

      destination_ranges = [
        local.cidr["subnet-mgmt"],
      ]

      allow = [
        {
          protocol = "tcp"
          ports    = ["8082", "8083"]
        },
      ]

      deny = []
    }

    "prometheus-to-traefik-public-dev" = {
      description        = "Allow Prometheus in dev-private to scrape public-facing Traefik's metrics endpoint in dev-public"
      direction          = "INGRESS"
      priority           = 1000
      source_ranges      = [local.cidr["subnet-dev-private"]]
      destination_ranges = [local.cidr["subnet-dev-public"]]

      allow = [
        {
          protocol = "tcp"
          ports    = ["8082"]
        },
      ]

      deny = []
    }

    "prometheus-to-traefik-public-prod" = {
      description        = "Allow Prometheus in prod-private to scrape public-facing Traefik's metrics endpoint in prod-public"
      direction          = "INGRESS"
      priority           = 1000
      source_ranges      = [local.cidr["subnet-prod-private"]]
      destination_ranges = [local.cidr["subnet-prod-public"]]

      allow = [
        {
          protocol = "tcp"
          ports    = ["8082"]
        },
      ]

      deny = []
    }
  }
}

resource "google_compute_firewall" "this" {
  for_each = local.rules

  project   = var.project_id
  name      = each.key
  description = each.value.description
  network   = var.network_self_link
  direction = each.value.direction
  priority  = each.value.priority

  source_ranges       = each.value.source_ranges
  destination_ranges  = each.value.destination_ranges

  dynamic "allow" {
    for_each = each.value.allow
    content {
      protocol = allow.value.protocol
      ports    = allow.value.ports
    }
  }

  dynamic "deny" {
    for_each = each.value.deny
    content {
      protocol = deny.value.protocol
      ports    = deny.value.ports
    }
  }
}
