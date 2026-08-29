# Shared Library Variable Set
#
# Values every project's deployment process needs in common. Anything
# specific to a single project (e.g. replica count) is set on that
# project directly in projects.tf instead of duplicated here.

locals {
  dummy_token      = "hvs.CAESIJ_placeholder_token_for_testing"
  dummy_webhook    = "https://hooks.slack.com/services/T00/B00/XXXXX"
}

resource "octopusdeploy_library_variable_set" "platform_shared" {
  name        = "platform-shared"
  description = "Nomad connection details and deployment configuration shared across every project's deployment process."
}

data "google_secret_manager_secret_version" "octopus_deploy_token" {
  for_each = var.use_dummy_secrets ? [] : toset(["dev", "prod"])
  secret   = "octopus-deploy-token-${each.key}"
}

data "google_secret_manager_secret_version" "slack_webhook_url" {
  count  = var.use_dummy_secrets ? 0 : 1
  secret = var.slack_webhook_secret_name
}

locals {
  env_by_key = {
    dev  = octopusdeploy_environment.dev.id
    prod = octopusdeploy_environment.prod.id
  }
  nomad_address_by_env = {
    dev  = var.nomad_address_dev
    prod = var.nomad_address_prod
  }

  traefik_public_ip_by_env = {
    dev  = var.traefik_public_ip_dev
    prod = var.traefik_public_ip_prod
  }

  traefik_public_port_by_env = {
    dev  = var.traefik_public_port_dev
    prod = var.traefik_public_port_prod
  }

  traefik_internal_ip_by_env = {
    dev  = var.traefik_internal_ip_dev
    prod = var.traefik_internal_ip_prod
  }

  traefik_internal_port_by_env = {
    dev  = var.traefik_internal_port_dev
    prod = var.traefik_internal_port_prod
  }

  # Base image path — same registry regardless of environment, unlike
  # everything else that's split dev/prod. One repo, images promoted
  # through environments by tag, not rebuilt — per the architecture
  # doc's CI/CD design (GitHub Actions builds once per commit).
  artifact_registry_path = ""
}

resource "octopusdeploy_variable" "environment" {
  for_each = toset(["dev", "prod"])
  owner_id = octopusdeploy_library_variable_set.platform_shared.id
  name     = "Environment"
  type     = "String"
  value    = each.key
  scope {
    environments = [local.env_by_key[each.key]]
  }
}

resource "octopusdeploy_variable" "nomad_api_url" {
  for_each = toset(["dev", "prod"])
  owner_id = octopusdeploy_library_variable_set.platform_shared.id
  name     = "NomadApiUrl"
  type     = "String"
  value    = local.nomad_address_by_env[each.key]
  scope {
    environments = [local.env_by_key[each.key]]
  }
}

resource "octopusdeploy_variable" "nomad_acl_token" {
  for_each     = toset(["dev", "prod"])
  owner_id     = octopusdeploy_library_variable_set.platform_shared.id
  name         = "NomadAclToken"
  type         = "Sensitive"
  is_sensitive = true

  sensitive_value = var.use_dummy_secrets ? local.dummy_token : data.google_secret_manager_secret_version.octopus_deploy_token[each.key].secret_data

  scope {
    environments = [local.env_by_key[each.key]]
  }

  lifecycle {
    ignore_changes = [sensitive_value]
  }
}

resource "octopusdeploy_variable" "traefik_public_ip" {
  for_each = toset(["dev", "prod"])

  owner_id = octopusdeploy_library_variable_set.platform_shared.id
  name     = "TraefikPublicIp"
  type     = "String"
  value    = local.traefik_public_ip_by_env[each.key]

  scope {
    environments = [local.env_by_key[each.key]]
  }
}

resource "octopusdeploy_variable" "traefik_public_port" {
  for_each = toset(["dev", "prod"])

  owner_id = octopusdeploy_library_variable_set.platform_shared.id
  name     = "TraefikPublicPort"
  type     = "String"
  value    = local.traefik_public_port_by_env[each.key]

  scope {
    environments = [local.env_by_key[each.key]]
  }
}

resource "octopusdeploy_variable" "traefik_internal_ip" {
  for_each = toset(["dev", "prod"])

  owner_id = octopusdeploy_library_variable_set.platform_shared.id
  name     = "TraefikInternalIp"
  type     = "String"
  value    = local.traefik_internal_ip_by_env[each.key]

  scope {
    environments = [local.env_by_key[each.key]]
  }
}

resource "octopusdeploy_variable" "traefik_internal_port" {
  for_each = toset(["dev", "prod"])

  owner_id = octopusdeploy_library_variable_set.platform_shared.id
  name     = "TraefikInternalPort"
  type     = "String"
  value    = local.traefik_internal_port_by_env[each.key]

  scope {
    environments = [local.env_by_key[each.key]]
  }
}

resource "octopusdeploy_variable" "image_tag" {
  owner_id    = octopusdeploy_library_variable_set.platform_shared.id
  name        = "ImageTag"
  type        = "String"
  value       = "#{Octopus.Release.Number}"
  description = "Alias for the release number GitHub Actions sets when it calls octo create-release — the same image tag is promoted through every environment, never rebuilt."
}

resource "octopusdeploy_variable" "slack_webhook_url" {
  owner_id = octopusdeploy_library_variable_set.platform_shared.id
  name     = "SlackWebhookUrl"
  type     = "Sensitive"
  is_sensitive = true
  sensitive_value = var.use_dummy_secrets ? local.dummy_webhook : data.google_secret_manager_secret_version.slack_webhook_url[0].secret_data

  lifecycle {
    ignore_changes = [sensitive_value]
  }
}

resource "octopusdeploy_variable" "region" {
  for_each = toset(["dev", "prod"])
  owner_id = octopusdeploy_library_variable_set.platform_shared.id
  name     = "Region"
  type     = "String"
  value    = each.key
  scope {
    environments = [local.env_by_key[each.key]]
  }
}


resource "octopusdeploy_variable" "datacenter" {
  for_each = toset(["dev", "prod"])
  owner_id = octopusdeploy_library_variable_set.platform_shared.id
  name     = "Datacenter"
  type     = "String"
  value    = "dc-${each.key}"
  scope {
    environments = [local.env_by_key[each.key]]
  }
}

resource "octopusdeploy_variable" "artifact_registry" {
  owner_id = octopusdeploy_library_variable_set.platform_shared.id
  name     = "ArtifactRegistry"
  type     = "String"
  value    = local.artifact_registry_path # e.g. "us-central1-docker.pkg.dev/${var.gcp_project_id}/platform-images"
}
