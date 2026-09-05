# Deployment Process

data "octopusdeploy_feeds" "builtin" {
  feed_type = "BuiltIn"
}

resource "octopusdeploy_process" "this" {
  for_each   = local.projects
  project_id = octopusdeploy_project.this[each.key].id
}

locals {
  deploy_steps    = ["validate-nomad-job", "deploy-to-nomad", "wait-for-healthy", "promote-deployment", "notify-slack"]
  builtin_feed_id = data.octopusdeploy_feeds.builtin.feeds[0].id
}

resource "octopusdeploy_process_step" "this" {
  for_each = { for pair in setproduct(keys(local.projects), local.deploy_steps) : "${pair[0]}-${pair[1]}" => {
    project = pair[0]
    step    = pair[1]
  } }

  process_id     = octopusdeploy_process.this[each.value.project].id
  name           = each.value.step
  type           = "Octopus.Script"
  condition = each.value.step == "notify-slack" ? "Always" : "Success"
  worker_pool_id = octopusdeploy_static_worker_pool.nomad_deployments.id

  properties = {
    "Octopus.Action.TargetRoles" = "nomad-cluster"
  }

  primary_package = {
    package_id = each.value.project
    feed_id    = local.builtin_feed_id
  }

  execution_properties = {
    "Octopus.Action.RunOnServer"  = "True"
    "Octopus.Action.Script.ScriptSource"   = "Package"
    "Octopus.Action.Script.ScriptFileName" = "scripts/${each.value.step}.sh"
  }
}

resource "octopusdeploy_process_steps_order" "this" {
  for_each   = local.projects
  process_id = octopusdeploy_process.this[each.key].id
  steps = [
    for step in local.deploy_steps : octopusdeploy_process_step.this["${each.key}-${step}"].id
  ]
}
