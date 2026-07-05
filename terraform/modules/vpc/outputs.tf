output "network_id" {
  description = "Self-link / ID of the VPC, needed by firewall, NAT, DNS, and compute layers."
  value       = google_compute_network.this.id
}

output "network_self_link" {
  value = google_compute_network.this.self_link
}

output "network_name" {
  value = google_compute_network.this.name
}

output "subnets" {
  description = "Map of subnet name to its resource attributes (id, self_link, ip_cidr_range)."
  value = {
    for name, subnet in google_compute_subnetwork.this : name => {
      id             = subnet.id
      self_link      = subnet.self_link
      ip_cidr_range  = subnet.ip_cidr_range
      region         = subnet.region
    }
  }
}
