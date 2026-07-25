output "instances" {
  value = module.instances.instances
}

output "mig_instance_groups" {
  value = module.nomad_client_mig.instance_groups
}
