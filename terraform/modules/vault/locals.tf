# Consumer Catalog — Single Source Of Truth
# Every service needing a Vault policy + Nomad Workload Identity role is
# defined once here. policies.tf and auth-nomad.tf both read from this
# map via for_each instead of hardcoding a near-identical block per
# service. The 10 remaining Online Boutique services with no Vault
# secret dependency (per the architecture doc's service table) are
# intentionally absent — no Vault policy needed for a service that never
# calls Vault.
locals {
  vault_consumers = {
    "cartservice" = {
      namespace = "default"
      kv_paths  = ["cartservice/redis"]
      db_role   = null
    }
    "metrics-api" = {
      namespace = "default"
      kv_paths  = []
      db_role   = "metrics-api" # database/creds/{env}-metrics-api
    }
    "ai-agent" = {
      namespace = "monitoring"
      kv_paths  = ["ai-agent/config"]
      db_role   = "monitoring" # database/creds/{env}-monitoring — nomad-sentinel's agent_anomalies DB
    }
  }
}
