output "instances" {
  description = "Map of instance name to its attributes — internal/external IP, self_link, etc."
  value = {
    for name, instance in google_compute_instance.this : name => {
      self_link    = instance.self_link
      internal_ip  = instance.network_interface[0].network_ip
      external_ip  = try(instance.network_interface[0].access_config[0].nat_ip, null)
      zone         = instance.zone
    }
  }
}
