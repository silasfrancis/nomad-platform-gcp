# Cloud Router + Cloud NAT
#
# Only subnet-mgmt, subnet-dev-private, and subnet-prod-private are NATed —
# these hosts have no public IP. subnet-dev-public / subnet-prod-public
# instances (Traefik) get direct internet access via their own public IP
# and are intentionally excluded here.

resource "google_compute_router" "this" {
  project = var.project_id
  name    = "nomad-platform-router"
  region  = var.region
  network = var.network_id
}

resource "google_compute_router_nat" "this" {
  project                            = var.project_id
  name                                = "nomad-platform-nat"
  router                              = google_compute_router.this.name
  region                               = var.region
  nat_ip_allocate_option               = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat  = "LIST_OF_SUBNETWORKS"

  dynamic "subnetwork" {
    for_each = var.nat_subnet_self_links
    content {
      name                    = subnetwork.value
      source_ip_ranges_to_nat = ["ALL_IP_RANGES"]
    }
  }

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}
