# Project-Scoped Variables
#
# Namespace and replica count are properties of the SERVICE, not the
# environment — cartservice deploys into "boutique" whether it's dev or
# prod, so these are set once per project rather than duplicated per
# environment the way NomadApiUrl/NomadAclToken need to be.
#
# ReplicaCount defaults to 1 for every project — a placeholder until
# actual per-service scaling requirements are decided when nomad-jobs/
# is written. Override per project below if a specific service needs a
# different starting value.
locals {
  replica_count_overrides = {
    frontend = 2
  }
}

resource "octopusdeploy_variable" "deployment_namespace" {
  for_each = local.projects
  owner_id = octopusdeploy_project.this[each.key].id
  name     = "DeploymentNamespace"
  type     = "String"
  value    = each.value.namespace
}

resource "octopusdeploy_variable" "replica_count" {
  for_each = local.projects
  owner_id = octopusdeploy_project.this[each.key].id
  name     = "ReplicaCount"
  type     = "String"
  value    = tostring(lookup(local.replica_count_overrides, each.key, 1))
}
