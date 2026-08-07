# Vault Workload Identity Consumer Catalog
#
# Every Nomad job that needs a Vault identity is defined once here.
# policies.tf and auth-nomad.tf both loop over this map with for_each,
# so adding a new consumer means adding one entry here rather than
# touching multiple files.
locals {
  vault_consumers = {
    "postgres" = {
      namespace = "datastore"
      kv_paths  = ["shared/postgres/admin"]
      db_role   = null
    }
    "redis" = {
      namespace = "datastore"
      kv_paths  = ["shared/redis"]
      db_role   = null
    }
    "cartservice" = {
      namespace = "boutique"
      kv_paths  = ["shared/redis"]
      db_role   = null
    }
    "metrics-api" = {
      namespace = "monitoring"
      kv_paths  = []
      db_role   = "metrics-api"
    }
    "nomad-sentinel" = {
      namespace = "monitoring"
      kv_paths  = ["nomad-sentinel/config"]
      db_role   = "monitoring"
    }
    "prometheus" = {
      namespace = "monitoring"
      kv_paths  = ["prometheus/config"]
      db_role   = null
    }
    "consul-snapshot" = {
      namespace = "operations"
      kv_paths  = ["backup/consul-token"]
      db_role   = null
    }
    "postgres-backup" = {
      namespace = "operations"
      kv_paths  = ["shared/postgres/admin"]
      db_role   = null
    }
    "nomad-autoscaler" = {
      namespace = "plugins"
      kv_paths  = []
      db_role   = null
    }
  }
}
