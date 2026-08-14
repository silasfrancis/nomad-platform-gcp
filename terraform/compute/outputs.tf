output "instances" {
  value = module.instances.instances
}

output "mig" {
  value = module.mig.instance_groups
}

output "persistent_disks" {
  value = module.instances.persistent_disks
}