# Shared Library Variable Set — NomadToken, VaultAddr, ImageTag,
# Datacenter, RemediationMode, ResourceLimits, Per Environment (per
# architecture doc section 6.5's variable table).
#
# NOTE: library variable set resource naming/schema not independently
# verified against current provider docs this session — flagging rather
# than asserting confidence. octopusdeploy_library_variable_set plus
# octopusdeploy_variable (owner_id pointing at the set) is the general
# shape, but confirm exact argument names before first apply.

resource "octopusdeploy_library_variable_set" "platform_shared" {
  name = "platform-shared"
}

data "google_secret_manager_secret_version" "octopus_deploy_token" {
  for_each = toset(["dev", "prod"])
  secret   = "octopus-deploy-token-${each.key}" # written by nomad/ root module
}

resource "octopusdeploy_variable" "nomad_token" {
  for_each     = toset(["dev", "prod"])
  owner_id     = octopusdeploy_library_variable_set.platform_shared.id
  name         = "NomadToken"
  type         = "Sensitive"
  is_sensitive = true
  value        = data.google_secret_manager_secret_version.octopus_deploy_token[each.key].secret_data

  scope {
    environments = [
      each.key == "dev" ? octopusdeploy_environment.dev.id : octopusdeploy_environment.prod.id
    ]
  }
}

resource "octopusdeploy_variable" "vault_addr" {
  owner_id = octopusdeploy_library_variable_set.platform_shared.id
  name     = "VaultAddr"
  type     = "String"
  value    = "https://vault.platform.lefrancis.org:8200"
}

resource "octopusdeploy_variable" "remediation_mode" {
  for_each = toset(["dev", "prod"])
  owner_id = octopusdeploy_library_variable_set.platform_shared.id
  name     = "RemediationMode"
  type     = "String"
  value    = each.key == "dev" ? "execute" : "propose"

  scope {
    environments = [
      each.key == "dev" ? octopusdeploy_environment.dev.id : octopusdeploy_environment.prod.id
    ]
  }
}

# ImageTag/Datacenter/ResourceLimits omitted here — these vary per
# *release*, not per fixed platform config (ImageTag = release number,
# ResourceLimits differs by project not just by env). Better modeled as
# project-scoped variables or release-time substitution once
# nomad-jobs/ actually exists to reference — placeholder, not written.
