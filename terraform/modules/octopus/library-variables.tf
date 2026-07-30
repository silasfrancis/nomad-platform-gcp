# Shared Library Variable Set
#
# Values every project's deployment process needs in common. Anything
# specific to a single project (e.g. replica count) is set on that
# project directly in projects.tf instead of duplicated here.
resource "octopusdeploy_library_variable_set" "platform_shared" {
  name        = "platform-shared"
  description = "Nomad connection details and deployment configuration shared across every project's deployment process."
}

data "google_secret_manager_secret_version" "octopus_deploy_token" {
  for_each = toset(["dev", "prod"])
  secret   = "octopus-deploy-token-${each.key}"
}

data "google_secret_manager_secret_version" "ca_cert" {
  for_each = toset(["dev", "prod"])
  secret   = "ca-cert-${each.key}"
}

data "google_secret_manager_secret_version" "slack_webhook_url" {
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
  value        = data.google_secret_manager_secret_version.octopus_deploy_token[each.key].secret_data
  scope {
    environments = [local.env_by_key[each.key]]
  }
}

resource "octopusdeploy_variable" "nomad_ca_cert" {
  for_each     = toset(["dev", "prod"])
  owner_id     = octopusdeploy_library_variable_set.platform_shared.id
  name         = "NomadCaCert"
  type         = "Sensitive"
  is_sensitive = true
  value        = data.google_secret_manager_secret_version.ca_cert[each.key].secret_data
  scope {
    environments = [local.env_by_key[each.key]]
  }
}

resource "octopusdeploy_variable" "image_tag" {
  owner_id = octopusdeploy_library_variable_set.platform_shared.id
  name     = "ImageTag"
  type     = "String"
  value    = "#{Octopus.Release.Number}"
  description = "Alias for the release number GitHub Actions sets when it calls octo create-release — the same image tag is promoted through every environment, never rebuilt."
}

resource "octopusdeploy_variable" "slack_webhook_url" {
  owner_id     = octopusdeploy_library_variable_set.platform_shared.id
  name         = "SlackWebhookUrl"
  type         = "Sensitive"
  is_sensitive = true
  value        = data.google_secret_manager_secret_version.slack_webhook_url.secret_data
}
