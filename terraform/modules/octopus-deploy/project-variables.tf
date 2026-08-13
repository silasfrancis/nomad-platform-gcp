# Project-Scoped Variables

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
  value    = each.key == "prod" ? "boutique.lefrancis.org" : "dev.boutique.lefrancis.org"
  scope {
    environments = [local.env_by_key[each.key]]
  }
}

resource "octopusdeploy_variable" "remediation_mode" {
  for_each = toset(["dev", "prod"])
  owner_id = octopusdeploy_project.this["monitoring"].id
  name     = "RemediationMode"
  type     = "String"
  value    = each.key == "prod" ? "propose" : "execute"
  scope {
    environments = [local.env_by_key[each.key]]
  }
}