# Deployment Targets
#
# Nomad is reached via a script step calling the Nomad CLI/API
# directly — there is no Tentacle agent or machine to connect to.
# Cloud Region is Octopus's target type for exactly this case: a
# logical target with no agent requirement, existing purely so a
# deployment process has something to scope and report against.
resource "octopusdeploy_cloud_region_deployment_target" "nomad_dev" {
  name         = "nomad-dev"
  environments = [octopusdeploy_environment.dev.id]
  roles        = ["nomad-cluster"]
}

resource "octopusdeploy_cloud_region_deployment_target" "nomad_prod" {
  name         = "nomad-prod"
  environments = [octopusdeploy_environment.prod.id]
  roles        = ["nomad-cluster"]
}
