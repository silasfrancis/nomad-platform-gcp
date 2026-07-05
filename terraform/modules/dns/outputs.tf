output "zone_name" {
  description = "Managed zone name, needed by compute/ to add recordsets."
  value       = google_dns_managed_zone.platform_private.name
}

output "dns_name" {
  value = google_dns_managed_zone.platform_private.dns_name
}
