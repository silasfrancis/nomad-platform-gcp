# Firewall Rules
#
# Per architecture doc section 1.2, plus additions found while reasoning
# through actual traffic flows (Consul HTTP API, Traefik-to-frontend
# routing) that weren't in the doc's original table.
#
# Destinations are scoped with destination_ranges (subnet CIDR membership)
# rather than target_tags. A CIDR-based destination can't drift out of
# sync with reality — any instance launched into a given subnet
# automatically matches. A tag-based destination depends on compute/
# applying the exact right tag string to every instance/MIG template;
# miss one and the rule silently doesn't apply, with no error. Sources
# use the same CIDR-based approach for the same reason (over source_tags).
#
# Priority: lower number evaluates first. Deny rules sit at 900, below the
# 1000 default used for allow rules, so the explicit cross-env deny wins
# over the broader internal-allow rules for any dev<->prod traffic.

locals {
  cidr = var.subnet_cidrs

  rules = {
    "iap-ssh" = {
      direction     = "INGRESS"
      priority      = 1000
      source_ranges = ["35.235.240.0/20"]
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

    # IAP tunnel access to traefik-internal's 5 HTTPS entrypoints —
    # mgmt (8443), dev-internal (8444), prod-internal (8445), and the
    # two dedicated "internal" entrypoints added for Grafana/falco-webhook
    # access (8446/8447). Every scripts/open-tunnel.sh invocation
    # tunnels through IAP to one of these — without this rule, none of
    # them actually work, same as SSH needing its own rule above.
    "iap-traefik-internal" = {
      direction           = "INGRESS"
      priority            = 1000
      source_ranges       = ["35.235.240.0/20"]
      destination_ranges  = [local.cidr["subnet-mgmt"]]
      allow               = [{ protocol = "tcp", ports = ["8443-8447"] }]
      deny                = []
    }

    "deny-dev-to-prod" = {
      direction           = "INGRESS"
      priority            = 900
      source_ranges       = [local.cidr["subnet-dev-private"]]
      destination_ranges  = [local.cidr["subnet-prod-private"]]
      allow               = []
      deny                = [{ protocol = "all", ports = [] }]
    }

    "deny-prod-to-dev" = {
      direction           = "INGRESS"
      priority            = 900
      source_ranges       = [local.cidr["subnet-prod-private"]]
      destination_ranges  = [local.cidr["subnet-dev-private"]]
      allow               = []
      deny                = [{ protocol = "all", ports = [] }]
    }

    "nomad-internal" = {
      direction = "INGRESS"
      priority  = 1000
      source_ranges = [
        local.cidr["subnet-dev-private"],
        local.cidr["subnet-prod-private"],
        local.cidr["subnet-mgmt"],
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
      direction = "INGRESS"
      priority  = 1000
      source_ranges = [
        local.cidr["subnet-dev-private"],
        local.cidr["subnet-prod-private"],
        local.cidr["subnet-mgmt"],
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

    "vault-internal" = {
      direction           = "INGRESS"
      priority            = 1000
      source_ranges       = [local.cidr["subnet-dev-private"], local.cidr["subnet-prod-private"]]
      destination_ranges  = [local.cidr["subnet-mgmt"]]
      allow               = [{ protocol = "tcp", ports = ["8200"] }]
      deny                = []
    }

    "consul-connect-sidecars" = {
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
      allow = [{ protocol = "tcp", ports = ["21000-21255"] }]
      deny  = []
    }

    "consul-catalog-dev-public" = {
      direction           = "INGRESS"
      priority            = 1000
      source_ranges       = [local.cidr["subnet-dev-public"]]
      destination_ranges  = [local.cidr["subnet-dev-private"]]
      allow               = [{ protocol = "tcp", ports = ["8501"] }]
      deny                = []
    }

    "consul-catalog-prod-public" = {
      direction           = "INGRESS"
      priority            = 1000
      source_ranges       = [local.cidr["subnet-prod-public"]]
      destination_ranges  = [local.cidr["subnet-prod-private"]]
        allow               = [{ protocol = "tcp", ports = ["8501"] }]
        deny                = []
      }

    "traefik-public" = {
      direction           = "INGRESS"
      priority            = 1000
      source_ranges       = ["0.0.0.0/0"]
      destination_ranges  = [local.cidr["subnet-dev-public"], local.cidr["subnet-prod-public"]]
      allow               = [{ protocol = "tcp", ports = ["80", "443"] }]
      deny                = []
    }

    "traefik-backend-dev" = {
      direction           = "INGRESS"
      priority            = 1000
      source_ranges       = [local.cidr["subnet-dev-public"]]
      destination_ranges  = [local.cidr["subnet-dev-private"]]
      allow               = [{ protocol = "tcp", ports = ["8080"] }]
      deny                = []
    }

    "traefik-backend-prod" = {
      direction           = "INGRESS"
      priority            = 1000
      source_ranges       = [local.cidr["subnet-prod-public"]]
      destination_ranges  = [local.cidr["subnet-prod-private"]]
      allow               = [{ protocol = "tcp", ports = ["8080"] }]
      deny                = []
    }

    # Everything traefik-internal and mgmt-vm need from each other —
    # one rule covers both directions since source and destination
    # CIDRs are identical (same subnet). Vault (8200)/Octopus (8080)/
    # Grafana (3000) for Traefik's own static routes to them; Traefik's
    # 5 entrypoints (8443-8447) for anything on mgmt-vm calling back
    # through Traefik; Vault's dedicated Postgres TCP passthrough
    # ports (15432/15433).
    "mgmt-internal" = {
      direction           = "INGRESS"
      priority            = 1000
      source_ranges       = [local.cidr["subnet-mgmt"]]
      destination_ranges  = [local.cidr["subnet-mgmt"]]
      allow = [
        { protocol = "tcp", ports = ["8200", "8080", "3000", "8443-8447", "15432", "15433"] },
      ]
      deny = []
    }

    # traefik-internal's dev-internal/prod-internal instances proxy
    # Grafana's access to Prometheus (9090), Loki (3100), and
    # falco-webhook (8080) — all three are Nomad-scheduled workloads
    # inside dev-private/prod-private (discovered via consulCatalog),
    # not fixed VMs, so this is genuinely a different flow from
    # vault-internal above (which reaches a real fixed VM).
    "mgmt-to-env-discovery" = {
      direction     = "INGRESS"
      priority      = 1000
      source_ranges = [local.cidr["subnet-mgmt"]]
      destination_ranges = [
        local.cidr["subnet-dev-private"],
        local.cidr["subnet-prod-private"],
      ]
      allow = [{ protocol = "tcp", ports = ["9090", "3100", "8080"] }]
      deny  = []
    }

    # Prometheus is deliberately not Connect-meshed (it scrapes real
    # ports directly — required for pull-based scraping), so this is
    # every real port it needs within its own environment. Explicit
    # list, matching this file's own CIDR-over-tags philosophy, at the
    # real cost of needing an addition here whenever a new scraped
    # service gets a genuinely new port — a broader same-subnet allow
    # (same reasoning consul-connect-sidecars already uses for its
    # 256-port range) is the alternative if that maintenance cost
    # isn't worth it to you.
    "prometheus-scrape-dev" = {
      direction           = "INGRESS"
      priority            = 1000
      source_ranges       = [local.cidr["subnet-dev-private"]]
      destination_ranges  = [local.cidr["subnet-dev-private"]]
      allow = [
        {
          protocol = "tcp"
          ports =  [
              "9100",          # node-exporter
              "20000-32000",   # Nomad dynamic allocation ports
            ]
        },
      ]
      deny = []
    }

    "prometheus-scrape-prod" = {
      direction           = "INGRESS"
      priority            = 1000
      source_ranges       = [local.cidr["subnet-prod-private"]]
      destination_ranges  = [local.cidr["subnet-prod-private"]]
      allow = [
        {
          protocol = "tcp"
          ports =  [
              "9100",          # node-exporter
              "20000-32000",   # Nomad dynamic allocation ports
            ]
        },
      ]
      deny = []
    }

    "prometheus-to-nomad-dev" = {
      direction           = "INGRESS"
      priority            = 1000
      source_ranges      = [local.cidr["subnet-dev-private"]]
      destination_ranges = [local.cidr["subnet-dev-private"]]

      allow = [
        {
          protocol = "tcp"
          ports    = ["4646"]
        },
      ]

      deny = []
    }

    "prometheus-to-nomad-prod" = {
      direction           = "INGRESS"
      priority            = 1000
      source_ranges      = [local.cidr["subnet-prod-private"]]
      destination_ranges = [local.cidr["subnet-prod-private"]]

      allow = [
        {
          protocol = "tcp"
          ports    = ["4646"]
        },
      ]

      deny = []
    }

    "prometheus-to-consul-dev" = {
      direction           = "INGRESS"
      priority            = 1000
      source_ranges      = [local.cidr["subnet-dev-private"]]
      destination_ranges = [local.cidr["subnet-dev-private"]]

      allow = [
        {
          protocol = "tcp"
          ports    = ["8501"]
        },
      ]

      deny = []
    }

    "prometheus-to-consul-prod" = {
      direction           = "INGRESS"
      priority            = 1000
      source_ranges      = [local.cidr["subnet-prod-private"]]
      destination_ranges = [local.cidr["subnet-prod-private"]]

      allow = [
        {
          protocol = "tcp"
          ports    = ["8501"]
        },
      ]

      deny = []
    }

      "prometheus-to-traefik-internal" = {
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
