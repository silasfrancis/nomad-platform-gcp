# Single Global VPC
#
# Subnet isolation provides dev/prod separation without VPC peering
# overhead. Firewall rules (separate module) enforce the hard deny
# between dev and prod subnets — this module only lays out the network
# and subnet CIDRs per the architecture doc section 1.1.

resource "google_compute_network" "this" {
  project                 = var.project_id
  name                     = var.network_name
  auto_create_subnetworks  = false
  routing_mode             = "REGIONAL"
}

locals {
  subnets = {
    "subnet-mgmt" = {
      cidr                     = "10.2.1.0/24"
      private_google_access    = true
      flow_logs                = false
    }
    "subnet-dev-private" = {
      cidr                     = "10.0.1.0/24"
      private_google_access    = true
      flow_logs                = false
    }
    "subnet-dev-public" = {
      cidr                     = "10.0.2.0/24"
      private_google_access    = false
      flow_logs                = false
    }
    "subnet-prod-private" = {
      cidr                     = "10.1.1.0/24"
      private_google_access    = true
      flow_logs                = true
    }
    "subnet-prod-public" = {
      cidr                     = "10.1.2.0/24"
      private_google_access    = false
      flow_logs                = true
    }
  }
}

resource "google_compute_subnetwork" "this" {
  for_each = local.subnets

  project                  = var.project_id
  name                     = each.key
  region                   = var.region
  network                  = google_compute_network.this.id
  ip_cidr_range            = each.value.cidr
  private_ip_google_access = each.value.private_google_access

  dynamic "log_config" {
    for_each = each.value.flow_logs ? [1] : []
    content {
      aggregation_interval = "INTERVAL_5_SEC"
      flow_sampling        = 0.5
      metadata             = "INCLUDE_ALL_METADATA"
    }
  }
}
