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
      pki_paths = []
      db_role   = null
    }
    "redis" = {
      namespace = "datastore"
      kv_paths  = ["shared/redis"]
      pki_paths = []
      db_role   = null
    }
    "cartservice" = {
      namespace = "boutique"
      kv_paths  = ["shared/redis"]
      pki_paths = []
      db_role   = null
    }
    "metrics-api" = {
      namespace = "monitoring"
      kv_paths  = []
      pki_paths = []
      db_role   = "metrics-api"
    }
    "nomad-sentinel" = {
      namespace = "monitoring"
      kv_paths  = ["nomad-sentinel/config"]
      pki_paths = ["nomad-ca"]
      db_role   = "monitoring"
    }
    "prometheus" = {
      namespace = "monitoring"
      kv_paths  = ["prometheus/config"]
      pki_paths = ["consul-ca"]
      db_role   = null
    }
    "consul-snapshot" = {
      namespace = "operations"
      kv_paths  = ["backup/consul-token"]
      pki_paths = ["consul-ca"]
      db_role   = null
    }
    "nomad-snapshot" = {
      namespace = "operations"
      kv_paths  = []
      pki_paths = ["nomad-ca"]
      db_role   = null
    }
    "postgres-backup" = {
      namespace = "operations"
      kv_paths  = ["shared/postgres/admin"]
      pki_paths = []
      db_role   = null
    }
    "postgres-migrations" = {
      namespace = "operations"
      kv_paths  = ["shared/postgres/admin"]
      pki_paths = []
      db_role   = null
    }
    "nomad-autoscaler" = {
      namespace = "plugins"
      kv_paths  = []
      pki_paths = ["nomad-ca"]
      db_role   = null
    }
  }
}