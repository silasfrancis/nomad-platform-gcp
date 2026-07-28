# Per-Consumer Policies — Data-Driven From locals.vault_consumers
#
# kv_paths entries starting with "shared/" are written and read exactly
# as given, no dev/prod prefix — matching how vault_kv_secret_v2 names
# actually get written in secrets.tf/postgres-admin-secrets.tf. Every
# other path gets the usual dev/prod expansion, since those secrets
# genuinely exist twice (e.g. cartservice's redis password, one per
# env).
resource "vault_policy" "consumer" {
  for_each = local.vault_consumers
  name     = "${each.key}-policy"

  policy = <<-EOT
    %{~ for p in each.value.kv_paths ~}
    %{~ if startswith(p, "shared/") ~}
    path "kv/data/${p}" {
      capabilities = ["read"]
    }
    %{~ else ~}
    path "kv/data/dev/${p}" {
      capabilities = ["read"]
    }
    path "kv/data/prod/${p}" {
      capabilities = ["read"]
    }
    %{~ endif ~}
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

# GitHub Actions OIDC — Read-Only, Same Path (Currently: Octopus API Key)
resource "vault_policy" "github_actions" {
  name = "github-actions"
  policy = <<-EOT
    path "kv/data/cicd/*" {
      capabilities = ["read"]
    }
  EOT
}
