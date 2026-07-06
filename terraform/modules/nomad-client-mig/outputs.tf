output "instance_groups" {
  description = "Map of MIG name to its instance group self_link (needed for Grafana/Prometheus service discovery, or a backend service later)."
  value = {
    for name, mig in google_compute_region_instance_group_manager.this : name => mig.instance_group
  }
}
