resource "octopusdeploy_project_group" "online_boutique" {
  name        = "Online Boutique"
  description = "The customer-facing e-commerce application and its supporting services."
}

resource "octopusdeploy_project_group" "platform" {
  name        = "Platform"
  description = "Internal platform services: datastore, monitoring, operations, and security."
}

# Project Catalog — Single Source Of Truth
#
# Five projects, not one per service — Octopus's free self-hosted
# license caps out at 10 projects (confirmed via the License Usage
# dashboard), and the original one-project-per-service model was
# already at 23. Projects now map to Nomad namespaces 1:1 instead of to
# individual services: boutique, datastore, monitoring, operations,
# security. Every service that used to have its own project now shares
# its namespace's project instead — which project a given CI-built item
# releases against is explicit in that item's config entry
# (octopus_project field in .github/configs/*.json), not implicit from
# a project-name-equals-service-name mapping anymore.
#
# What does NOT change: CI still creates one release per changed
# service, still with that service's own distinct PackageID + SHA
# version (see .github/workflows/*.yaml) — release creation is what
# binds a specific package to a specific release, same mechanism as
# before. Only which Octopus PROJECT that release belongs to changes.
locals {
  projects = {
    "boutique"   = { group = "boutique", namespace = "boutique" }
    "datastore"  = { group = "platform", namespace = "datastore" }
    "monitoring" = { group = "platform", namespace = "monitoring" }
    "operations" = { group = "platform", namespace = "operations" }
    "security"   = { group = "platform", namespace = "security" }
  }
}

resource "octopusdeploy_project" "this" {
  for_each = local.projects

  name              = each.key
  project_group_id  = each.value.group == "boutique" ? octopusdeploy_project_group.online_boutique.id : octopusdeploy_project_group.platform.id
  lifecycle_id      = octopusdeploy_lifecycle.main.id
  description       = "Deploys every service/tool routed here (via octopus_project in .github/configs/*.json) to the ${each.value.namespace} Nomad namespace."
  included_library_variable_sets = [
    octopusdeploy_library_variable_set.platform_shared.id
  ]
}
