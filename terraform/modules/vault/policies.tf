# Per-Consumer, Per-Environment Policies
#
# One policy per (consumer, environment) pair — NOT one shared policy
# per consumer covering both environments. A single shared policy would
# grant a dev workload read access to prod's KV paths and vice versa,
# since both jwt-nomad-dev's and jwt-nomad-prod's roles would reference
# the exact same policy name. Splitting by environment is what keeps a
# compromised dev task from reading prod secrets.

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
    %{ if each.value.service == "nomad-autoscaler" }
    path "gcp/static-account/nomad-autoscaler-${each.value.environment}/key" {
      capabilities = ["read"]
    }
    %{ endif }
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
    %{~ for p in each.value.config.pki_paths ~}
    path "kv/data/pki/${each.value.environment}/${p}" {
      capabilities = ["read"]
    }
    %{~ endfor ~}
    %{~ if each.value.config.db_role != null ~}
    path "database/creds/${each.value.environment == "prod" ? "${each.value.config.db_role}-prod" : "${each.value.config.db_role}-dev"}" {
      capabilities = ["read"]
    }
    %{~ endif ~}
  EOT
}


# GitHub Actions, scoped to the CI/CD variable path only.
resource "vault_policy" "github_actions" {
  name = "github-actions"
  policy = <<-EOT
    path "kv/data/cicd/*" {
      capabilities = ["read"]
    }
  EOT
}

# Vault snapshots/backup policy
resource "vault_policy" "snapshot" {
  name = "snapshot"
  policy = <<-EOT
    path "sys/storage/raft/snapshot" {
      capabilities = [
        "read",
        "update",
        "sudo",
      ]
    }
  EOT
}

resource "vault_policy" "grafana_admin" {
  name = "grafana-admin"
  policy = <<-EOT
    path "kv/shared/grafana/admin/*" {
      capabilities = ["read"]
    }
  EOT
}
