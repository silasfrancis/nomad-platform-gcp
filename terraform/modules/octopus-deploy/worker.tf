resource "octopusdeploy_static_worker_pool" "nomad_deployments" {
  name        = "nomad-deployments"
  description = "Worker with nomad/consul CLI tooling for Nomad deployment scripts"
  is_default  = false
}
