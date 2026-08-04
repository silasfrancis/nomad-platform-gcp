# Per-Consumer, Per-Environment Policies
#
# One policy per (consumer, environment) pair — NOT one shared policy
# per consumer covering both environments. A single shared policy would
# grant a dev workload read access to prod's KV paths and vice versa,
# since both jwt-nomad-dev's and jwt-nomad-prod's roles would reference
# the exact same policy name. Splitting by environment is what keeps a
# compromised dev task from reading prod secrets.
#
# "shared/" prefixed KV paths are the one exception — they're written
# and read at that literal path with no per-environment variant, since
# they're genuinely shared values (see postgres-admin-secrets.tf).
locals {
  consumer_env_pairs = {
    for pair in setproduct(["dev", "prod"], keys(local.vault_consumers)) :
    "${pair[1]}-${pair[0]}" => {
      environment = pair[0]
      service     = pair[1]
      config      = local.vault_consumers[pair[1]]
    }
  }
}

resource "vault_policy" "consumer" {
  for_each = local.consumer_env_pairs
  name     = "${each.value.service}-${each.value.environment}-policy"

  policy = <<-EOT
    %{~ for p in each.value.config.kv_paths ~}
    %{~ if startswith(p, "shared/") ~}
    path "kv/data/${p}" {
      capabilities = ["read"]
    }
    %{~ else ~}
    path "kv/data/${each.value.environment}/${p}" {
      capabilities = ["read"]
    }
    %{~ endif ~}
    %{~ endfor ~}
    %{~ if each.value.config.db_role != null ~}
    path "database/creds/${each.value.environment == "prod" ? "${each.value.config.db_role}-prod" : "${each.value.config.db_role}-dev"}" {
      capabilities = ["read"]
    }
    %{~ endif ~}
  EOT
}


# GitHub Actions — read-only, scoped to the CI/CD variable path only.
resource "vault_policy" "github_actions" {
  name = "github-actions"
  policy = <<-EOT
    path "kv/data/cicd/*" {
      capabilities = ["read"]
    }
  EOT
}
