# Project-Scoped Variables

# Project-scoped deployment variables

resource "octopusdeploy_variable" "deployment_namespace" {
  for_each = local.projects

  owner_id = octopusdeploy_project.this[each.key].id
  name     = "DeploymentNamespace"
  type     = "String"
  value    = each.value.namespace
}

resource "octopusdeploy_variable" "public_hostname" {
  for_each = toset(["dev", "prod"])

  owner_id = octopusdeploy_project.this["boutique"].id
  name     = "PublicHostname"
  type     = "String"

  value = each.key == "prod" ? "boutique.lefrancis.org" : "dev.boutique.lefrancis.org"

  scope {
    environments = [local.env_by_key[each.key]]
  }
}

resource "octopusdeploy_variable" "remediation_mode" {
  for_each = toset(["dev", "prod"])

  owner_id = octopusdeploy_project.this["monitoring"].id
  name     = "RemediationMode"
  type     = "String"

  value = each.key == "prod" ? "propose" : "execute"

  scope {
    environments = [local.env_by_key[each.key]]
  }
}

resource "octopusdeploy_variable" "fail_on_substitution_error" {
  for_each = local.projects

  owner_id = octopusdeploy_project.this[each.key].id
  name     = "OctopusShouldFailDeploymentOnSubstitutionFails"
  type     = "String"
  value    = "True"
}

# ReplicaCount — dev/prod value per project, excluding datastore.

resource "octopusdeploy_variable" "replica_count" {
  for_each = {
    for pair in setproduct(
      keys(local.replica_projects),
      keys(local.replica_defaults)
    ) :
    "${pair[0]}-${pair[1]}" => {
      project = pair[0]
      env     = pair[1]
    }
  }

  owner_id = octopusdeploy_project.this[each.value.project].id
  name     = "ReplicaCount"
  type     = "String"
  value    = tostring(local.replica_defaults[each.value.env])

  scope {
    environments = [local.env_by_key[each.value.env]]
  }
}