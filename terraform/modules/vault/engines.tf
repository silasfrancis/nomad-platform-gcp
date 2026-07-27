# Secrets Engines
#
# Design (finalized this session):
#   - Postgres container's own POSTGRES_USER/POSTGRES_PASSWORD is a
#     superuser, used ONLY to bootstrap the instance (create the
#     vault-admin role + both databases in the init script). Never used
#     by Vault, never rotated by Vault — it's dormant after first boot.
#   - vault-admin is a SEPARATE role, created BY the superuser during
#     init, granted CREATEROLE + ownership of both databases. THIS is
#     what Vault's connections authenticate as — matching the standard
#     enterprise pattern of Vault holding its own dedicated DB identity
#     rather than reusing the instance's root/superuser account, so
#     Vault's own `rotate-root` can be used on it later without ever
#     touching (or needing to know) the container's bootstrap password.
#   - metrics-api/nomad-sentinel get ZERO static credentials — fully
#     dynamic, minted/revoked by Vault per request via the roles below.
#
# One Postgres instance, two clusters (dev/prod) each running their own
# copy of it — hence 4 connections, not 2. Each environment's Vault
# connection reaches Postgres via that environment's own local Consul
# DNS resolver on mgmt-vm (127.0.0.1:8600 for dev, 127.0.0.1:8601 for
# prod — see the mgmt-vm dual Consul agent setup), never a raw IP.

resource "vault_mount" "kv" {
  path = "kv"
  type = "kv-v2"
}

resource "vault_mount" "database" {
  path = "database"
  type = "database"
}

locals {
  # Postgres always resolves as "postgresql.service.consul" in both
  # clusters (Consul doesn't prefix names by datacenter unless
  # federated) — the two environments are disambiguated by which local
  # agent's DNS port answers the query, not by hostname.
  postgres_consul_resolvers = {
    dev  = "postgresql.service.consul:5432?host=127.0.0.1:8600"
    prod = "postgresql.service.consul:5432?host=127.0.0.1:8601"
  }
  # NOTE: the ?host= query-string form above is illustrative — Postgres
  # connection strings don't natively support a custom-DNS-server
  # override this way. The actually-correct mechanism (pointing this
  # specific outbound connection at the right local Consul resolver
  # port rather than system DNS) needs to be verified against either
  # the PostgreSQL Go/lib driver Vault's plugin uses, or handled via a
  # per-environment /etc/hosts-style override or dnsmasq split-horizon
  # config on mgmt-vm. Flagging rather than asserting this resolves
  # cleanly — confirm before relying on it.
}

resource "vault_database_secret_backend_connection" "postgres_metrics" {
  for_each      = toset(["dev", "prod"])
  backend       = vault_mount.database.path
  name          = "postgres-metrics-${each.key}"
  allowed_roles = ["${each.key}-metrics-api"]

  postgresql {
    connection_url = "postgresql://{{username}}:{{password}}@${local.postgres_consul_resolvers[each.key]}/metrics?sslmode=disable"
    username        = "vault-admin"
    password        = random_password.vault_admin_db.result
  }
}

resource "vault_database_secret_backend_role" "metrics_api" {
  for_each = toset(["dev", "prod"])
  backend  = vault_mount.database.path
  name     = "${each.key}-metrics-api"
  db_name  = vault_database_secret_backend_connection.postgres_metrics[each.key].name

  creation_statements = [
    "CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}';",
    "GRANT CONNECT ON DATABASE metrics TO \"{{name}}\";",
    "GRANT CREATE ON SCHEMA public TO \"{{name}}\";", # needed for the app's own CREATE TABLE IF NOT EXISTS — Postgres 15+ no longer grants this by default
    "GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA public TO \"{{name}}\";",
  ]
  default_ttl = 3600
  max_ttl     = 3600
}

resource "vault_database_secret_backend_connection" "postgres_monitoring" {
  for_each      = toset(["dev", "prod"])
  backend       = vault_mount.database.path
  name          = "postgres-monitoring-${each.key}"
  allowed_roles = ["${each.key}-monitoring"]

  postgresql {
    connection_url = "postgresql://{{username}}:{{password}}@${local.postgres_consul_resolvers[each.key]}/monitoring?sslmode=disable"
    username        = "vault-admin"
    password        = random_password.vault_admin_db.result
  }
}

resource "vault_database_secret_backend_role" "monitoring" {
  for_each = toset(["dev", "prod"])
  backend  = vault_mount.database.path
  name     = "${each.key}-monitoring"
  db_name  = vault_database_secret_backend_connection.postgres_monitoring[each.key].name

  creation_statements = [
    "CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}';",
    "GRANT CONNECT ON DATABASE monitoring TO \"{{name}}\";",
    "GRANT CREATE ON SCHEMA public TO \"{{name}}\";", # nomad-sentinel's ensure_schema() needs this too
    "GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA public TO \"{{name}}\";",
  ]
  default_ttl = 3600
  max_ttl     = 3600
}
