# Per-Consumer Policies — Data-Driven From locals.vault_consumers
resource "vault_policy" "consumer" {
  for_each = local.vault_consumers
  name     = "${each.key}-policy"

  policy = <<-EOT
    %{~ for p in each.value.kv_paths ~}
    path "kv/data/dev/${p}" {
      capabilities = ["read"]
    }
    path "kv/data/prod/${p}" {
      capabilities = ["read"]
    }
    %{~ endfor ~}
    %{~ if each.value.db_role != null ~}
    path "database/creds/dev-${each.value.db_role}" {
      capabilities = ["read"]
    }
    path "database/creds/prod-${each.value.db_role}" {
      capabilities = ["read"]
    }
    %{~ endif ~}
  EOT
}

# NOTE — Flag 2 (resolved this session): there is deliberately no
# "nomad-server" policy here. Under Workload Identity, Nomad servers
# never authenticate to Vault themselves — only individual task
# allocations do, via their own signed JWT. A standing server-level
# Vault policy would be a leftover from the legacy static-token model.

# NOTE: Octopus Deploy has no Vault policy/AppRole here — traced through
# the actual data flow (NomadToken/VaultAddr/ImageTag/Datacenter/
# RemediationMode/ResourceLimits), Octopus never actually reads a Vault
# secret for anything in this design. NomadToken comes from nomad/'s
# Terraform via Secret Manager directly; the rest are static values or
# per-release variables. The AppRole this session originally built for
# it was speculative scope with no real consumer — dropped.

# GitHub Actions OIDC — Read-Only, Same Path (Currently: Octopus API Key)
resource "vault_policy" "github_actions" {
  name = "github-actions"
  policy = <<-EOT
    path "kv/data/cicd/*" {
      capabilities = ["read"]
    }
  EOT
}
