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
  for_each = var.use_dummy_secrets ? [] : local.environments
  secret   = "octopus-deploy-token-${each.key}"
}

data "google_secret_manager_secret_version" "slack_webhook_url" {
  count  = var.use_dummy_secrets ? 0 : 1
  secret = var.slack_webhook_secret_name
}


resource "octopusdeploy_variable" "environment" {
  for_each = local.environments
  owner_id = octopusdeploy_library_variable_set.platform_shared.id
  name     = "Environment"
  type     = "String"
  value    = each.key
  scope {
    environments = [local.env_by_key[each.key]]
  }
}

resource "octopusdeploy_variable" "nomad_api_url" {
  for_each = local.environments
  owner_id = octopusdeploy_library_variable_set.platform_shared.id
  name     = "NomadApiUrl"
  type     = "String"
  value    = local.nomad_address_by_env[each.key]
  scope {
    environments = [local.env_by_key[each.key]]
  }
}

resource "octopusdeploy_variable" "nomad_acl_token" {
  for_each     = local.environments
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
  for_each = local.environments

  owner_id = octopusdeploy_library_variable_set.platform_shared.id
  name     = "TraefikPublicIp"
  type     = "String"
  value    = local.traefik_public_ip_by_env[each.key]

  scope {
    environments = [local.env_by_key[each.key]]
  }
}

resource "octopusdeploy_variable" "traefik_public_port" {
  for_each = local.environments

  owner_id = octopusdeploy_library_variable_set.platform_shared.id
  name     = "TraefikPublicPort"
  type     = "String"
  value    = local.traefik_public_port_by_env[each.key]

  scope {
    environments = [local.env_by_key[each.key]]
  }
}

resource "octopusdeploy_variable" "traefik_internal_ip" {
  for_each = local.environments

  owner_id = octopusdeploy_library_variable_set.platform_shared.id
  name     = "TraefikInternalIp"
  type     = "String"
  value    = local.traefik_internal_ip_by_env[each.key]

  scope {
    environments = [local.env_by_key[each.key]]
  }
}

resource "octopusdeploy_variable" "traefik_internal_port" {
  for_each = local.environments

  owner_id = octopusdeploy_library_variable_set.platform_shared.id
  name     = "TraefikInternalPort"
  type     = "String"
  value    = local.traefik_internal_port_by_env[each.key]

  scope {
    environments = [local.env_by_key[each.key]]
  }
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

resource "octopusdeploy_variable" "image_tag" {
  owner_id = octopusdeploy_library_variable_set.platform_shared.id
  name     = "ImageTag"
  type     = "String"
  value    = "#{Octopus.Release.Number | Replace \"^.*\\.\" \"\"}"
}

resource "octopusdeploy_variable" "artifact_registry" {
  owner_id = octopusdeploy_library_variable_set.platform_shared.id
  name     = "ArtifactRegistry"
  type     = "String"
  value    = local.artifact_registry_path # e.g. "us-central1-docker.pkg.dev/${var.gcp_project_id}/platform-images"
}

# ServiceName — extracted from the release's pre-release tag.
# "0.0.0-cartservice.a03722a8" -> "cartservice"

resource "octopusdeploy_variable" "service_name" {
  owner_id = octopusdeploy_library_variable_set.platform_shared.id
  name     = "ServiceName"
  type     = "String"

  value = chomp(<<-EOT
    #{Octopus.Release.Number | Replace "^\d+\.\d+\.\d+-([a-zA-Z0-9-]+)\..*$" "$1"}
  EOT
  )
}


# CPU / Memory overrides — named Cpu[service] / Memory[service] to use
# Octostache's dynamic indexer syntax: #{Cpu[#{ServiceName}]}

resource "octopusdeploy_variable" "cpu_override" {
  for_each = local.cpu_overrides

  owner_id = octopusdeploy_library_variable_set.platform_shared.id
  name     = "Cpu[${each.key}]"
  type     = "String"
  value    = tostring(each.value)
}

resource "octopusdeploy_variable" "memory_override" {
  for_each = local.memory_overrides

  owner_id = octopusdeploy_library_variable_set.platform_shared.id
  name     = "Memory[${each.key}]"
  type     = "String"
  value    = tostring(each.value)
}

# Whether ServiceName has an override.

resource "octopusdeploy_variable" "cpu_is_overridden" {
  owner_id = octopusdeploy_library_variable_set.platform_shared.id
  name     = "CpuIsOverridden"
  type     = "String"

  value = chomp(<<-EOT
    #{ServiceName | Match "^(${local.cpu_service_regex})$"}
  EOT
  )
}

resource "octopusdeploy_variable" "memory_is_overridden" {
  owner_id = octopusdeploy_library_variable_set.platform_shared.id
  name     = "MemoryIsOverridden"
  type     = "String"

  value = chomp(<<-EOT
    #{ServiceName | Match "^(${local.memory_service_regex})$"}
  EOT
  )
}

# Final Cpu / Memory — what the Nomad templates reference as #{Cpu} /
# #{Memory}. Falls through to the default floor when unlisted.

resource "octopusdeploy_variable" "cpu" {
  owner_id = octopusdeploy_library_variable_set.platform_shared.id
  name     = "Cpu"
  type     = "String"

  value = chomp(<<-EOT
    #{if CpuIsOverridden}#{Cpu[#{ServiceName}]}#{else}${local.cpu_default}#{/if}
  EOT
  )

  depends_on = [
    octopusdeploy_variable.cpu_override,
    octopusdeploy_variable.cpu_is_overridden
  ]
}

resource "octopusdeploy_variable" "memory" {
  owner_id = octopusdeploy_library_variable_set.platform_shared.id
  name     = "Memory"
  type     = "String"

  value = chomp(<<-EOT
    #{if MemoryIsOverridden}#{Memory[#{ServiceName}]}#{else}${local.memory_default}#{/if}
  EOT
  )

  depends_on = [
    octopusdeploy_variable.memory_override,
    octopusdeploy_variable.memory_is_overridden
  ]
}
