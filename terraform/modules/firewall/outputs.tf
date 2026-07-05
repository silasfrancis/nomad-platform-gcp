output "firewall_rule_names" {
  value = [for r in google_compute_firewall.this : r.name]
}
