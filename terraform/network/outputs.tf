output "network_id" {
  value = module.vpc.network_id
}

output "network_self_link" {
  value = module.vpc.network_self_link
}

output "subnets" {
  value = module.vpc.subnets
}

output "dns_zone_name" {
  value = module.dns.zone_name
}
