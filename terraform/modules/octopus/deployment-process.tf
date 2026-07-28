# Deployment Process
#
# One process per project, generated from the same project catalog
# used everywhere else in this module. Every project gets the same
# five-step shape — the actual behavior differs only through the
# DeploymentNamespace/ReplicaCount/ImageTag variables each script
# reads at runtime, not through different step definitions per
# project.
#
# Scripts are versioned in .github/workflows/scripts/ and packaged with
# each release artifact rather than written inline here, so they can be
# tested and reviewed like any other source file. Octopus extracts the
# package before running each step; WorkingDirectory below points at
# wherever that extraction lands.
resource "octopusdeploy_process" "this" {
  for_each   = local.projects
  project_id = octopusdeploy_project.this[each.key].id
}

locals {
  deploy_steps = ["validate-nomad-job", "deploy-to-nomad", "wait-for-healthy", "smoke-test", "notify-slack"]
}

resource "octopusdeploy_process_step" "this" {
  for_each = { for pair in setproduct(keys(local.projects), local.deploy_steps) : "${pair[0]}-${pair[1]}" => {
    project = pair[0]
    step    = pair[1]
  } }

  process_id = octopusdeploy_process.this[each.value.project].id
  name       = each.value.step
  type       = "Octopus.Script"

  properties = {
    "Octopus.Action.TargetRoles" = "nomad-cluster"
  }

  execution_properties = {
    "Octopus.Action.RunOnServer"          = "True"
    "Octopus.Action.Script.ScriptSource"  = "Package"
    "Octopus.Action.Script.ScriptFileName" = "${each.value.step}.sh"
    "Octopus.Action.Script.Syntax"        = "Bash"
  }
}

resource "octopusdeploy_process_steps_order" "this" {
  for_each   = local.projects
  process_id = octopusdeploy_process.this[each.key].id
  steps = [
    for step in local.deploy_steps : octopusdeploy_process_step.this["${each.key}-${step}"].id
  ]
}
