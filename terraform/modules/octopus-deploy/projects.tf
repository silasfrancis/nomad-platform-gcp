resource "octopusdeploy_project_group" "online_boutique" {
  name        = "Online Boutique"
  description = "The customer-facing e-commerce application and its supporting services."
}

resource "octopusdeploy_project_group" "platform" {
  name        = "Platform"
  description = "Internal platform services: the metrics API and the AI monitoring agent."
}

# Project Catalog — Single Source Of Truth
#
# Maps every Octopus project to the Nomad namespace it deploys into.
# Both the deployment-process resources and the shared variable
# resources read from this map, so adding a project means adding one
# entry here rather than touching multiple files.
locals {
  projects = {
    "frontend"               = { group = "boutique", namespace = "boutique" }
    "cartservice"             = { group = "boutique", namespace = "boutique" }
    "checkoutservice"         = { group = "boutique", namespace = "boutique" }
    "productcatalogservice"   = { group = "boutique", namespace = "boutique" }
    "currencyservice"         = { group = "boutique", namespace = "boutique" }
    "paymentservice"          = { group = "boutique", namespace = "boutique" }
    "shippingservice"         = { group = "boutique", namespace = "boutique" }
    "emailservice"            = { group = "boutique", namespace = "boutique" }
    "recommendationservice"   = { group = "boutique", namespace = "boutique" }
    "adservice"               = { group = "boutique", namespace = "boutique" }
    "loadgenerator"           = { group = "boutique", namespace = "boutique" }
    "metrics-api"             = { group = "platform", namespace = "monitoring" }
    "nomad-sentinel"          = { group = "platform", namespace = "monitoring" }
    "loki"                    = { group = "platform", namespace = "monitoring" }
    "prometheus"             = { group = "platform", namespace = "monitoring" }
    "alloy"                   = { group = "platform", namespace = "monitoring" }
    "falco-webhook"           = { group = "platform", namespace = "security" }
    "node-exporter"            = { group = "platform", namespace = "monitoring" }
    "postgres"                 = { group = "platform", namespace = "datastore" }
    "redis"                    = { group = "platform", namespace = "datastore" }
    "consul-snapshot"          = { group = "platform", namespace = "operations" }
    "postgres-backup"          = { group = "platform", namespace = "operations" }
    "docker-cleanup"           = { group = "platform", namespace = "operations" }
  }
}

resource "octopusdeploy_project" "this" {
  for_each = local.projects

  name             = each.key
  project_group_id = each.value.group == "boutique" ? octopusdeploy_project_group.online_boutique.id : octopusdeploy_project_group.platform.id
  lifecycle_id     = octopusdeploy_lifecycle.main.id
  description      = "Deploys ${each.key} to the ${each.value.namespace} Nomad namespace."
}
