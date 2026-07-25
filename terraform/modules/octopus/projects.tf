resource "octopusdeploy_project_group" "online_boutique" {
  name = "Online Boutique"
}

resource "octopusdeploy_project_group" "platform" {
  name = "Platform"
}

locals {
  boutique_projects = toset([
    "frontend", "cartservice", "checkoutservice", "productcatalogservice",
    "currencyservice", "paymentservice", "shippingservice", "emailservice",
    "recommendationservice", "adservice", "loadgenerator",
  ])
  platform_projects = toset(["metrics-api", "nomad-sentinel"])
}

resource "octopusdeploy_project" "boutique" {
  for_each         = local.boutique_projects
  name             = each.key
  project_group_id = octopusdeploy_project_group.online_boutique.id
  lifecycle_id     = octopusdeploy_lifecycle.main.id
}

resource "octopusdeploy_project" "platform" {
  for_each         = local.platform_projects
  name             = each.key
  project_group_id = octopusdeploy_project_group.platform.id
  lifecycle_id     = octopusdeploy_lifecycle.main.id
}
