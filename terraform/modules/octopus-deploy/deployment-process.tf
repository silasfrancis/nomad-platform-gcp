# Deployment Process
#
# One process per project (5 total, per projects.tf), same five-step
# shape for every one of them regardless of how many services release
# against it — validate-nomad-job, deploy-to-nomad, wait-for-healthy,
# smoke-test, notify-slack. Steps are NOT per-service; a project like
# "monitoring" has exactly these 5 steps whether one release only
# touches loki or another only touches nomad-sentinel. What varies
# between releases of the same project is which package (PackageID +
# version) CI bound to that release at creation time — deploy-to-nomad.sh
# reads whatever job spec file is actually present in the extracted
# package and acts on that, so the script itself needs no per-service
# knowledge baked into the process definition at all.
#
# DeploymentNamespace is the one variable every step still needs and
# still gets, project-scoped, flat (see project-variables.tf) — it's
# the same for every service sharing a project by construction, since
# that's the entire reason services are grouped by namespace here.
# Cpu/Memory/ReplicaCount/PublicHostname/RemediationMode do NOT have
# project-level homes anymore; they moved into the relevant service's
# own job spec file (see project-variables.tf's header for why).
#
# Scripts are versioned in octopus/deployment-scripts/ and packaged
# with each release artifact rather than written inline here, so they
# can be tested and reviewed like any other source file. Octopus
# extracts the package before running each step; WorkingDirectory
# below points at wherever that extraction lands.
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

  primary_package = {
    package_id = "each.value.project"
  }

  execution_properties = {
    "Octopus.Action.RunOnServer"           = "True"
    "Octopus.Action.Script.ScriptSource"   = "Package"
    "Octopus.Action.Script.ScriptFileName" = "scripts/${each.value.step}.sh"
    "Octopus.Action.Script.Syntax"         = "Bash"
  }
}
resource "octopusdeploy_process_steps_order" "this" {
  for_each   = local.projects
  process_id = octopusdeploy_process.this[each.key].id
  steps = [
    for step in local.deploy_steps : octopusdeploy_process_step.this["${each.key}-${step}"].id
  ]
}
