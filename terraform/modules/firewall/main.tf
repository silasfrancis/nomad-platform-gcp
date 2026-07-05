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

    "traefik-public" = {
      direction     = "INGRESS"
      priority      = 1000
      source_ranges = ["0.0.0.0/0"]
      destination_ranges = [
        local.cidr["subnet-dev-public"],
        local.cidr["subnet-prod-public"],
      ]
      allow = [{ protocol = "tcp", ports = ["80", "443"] }]
      deny  = []
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
        { protocol = "tcp", ports = ["8300", "8301", "8302", "8500"] },
        { protocol = "udp", ports = ["8301", "8302"] },
      ]
      deny = []
    }

    "vault-internal" = {
      direction = "INGRESS"
      priority  = 1000
      source_ranges = [
        local.cidr["subnet-dev-private"],
        local.cidr["subnet-prod-private"],
      ]
      destination_ranges = [local.cidr["subnet-mgmt"]]
      allow               = [{ protocol = "tcp", ports = ["8200"] }]
      deny                = []
    }

    "grafana-query" = {
      # Grafana runs on mgmt (systemd) and queries Prometheus + Loki, both
      # of which run per-environment as Nomad jobs on dev/prod client nodes
      # (architecture doc section 8.1). node_exporter (9100) is scraped
      # in-cluster by each environment's own Prometheus via Consul catalog
      # SD — mgmt never touches 9100 directly, so no rule is needed for it.
      # 9090 = Prometheus HTTP/query API, 3100 = Loki HTTP/query API.
      direction           = "INGRESS"
      priority            = 1000
      source_ranges       = [local.cidr["subnet-mgmt"]]
      destination_ranges  = [
        local.cidr["subnet-dev-private"],
        local.cidr["subnet-prod-private"],
      ]
      allow = [{ protocol = "tcp", ports = ["9090", "3100"] }]
      deny  = []
    }

    # Traefik (public) proxies only frontend:8080 into its own environment's
    # private subnet (architecture doc section 4.3 — no other backend service
    # is routed through Traefik). Split per-environment rather than one rule
    # spanning both public CIDRs, because deny-dev-to-prod/deny-prod-to-dev
    # only match *-private source CIDRs — a combined public->private rule
    # here would reopen a dev-public -> prod-private path those deny rules
    # don't cover.
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
