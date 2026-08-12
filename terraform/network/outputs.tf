output "network_id" {
  value = module.vpc.network_id
}

output "network_self_link" {
  value = module.vpc.network_self_link
}

output "subnets" {
  value = module.vpc.subnets
}

output "internal_dns_zone_name" {
  value = module.internal_dns.zone_name
}


output "internal_dns_suffix" {
  value = module.internal_dns.dns_name
}