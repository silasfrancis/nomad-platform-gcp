# Secrets Engines
#
# Static secrets (kv) and dynamic database credentials (database) live
# in separate mounts, since they're managed very differently — kv holds
# values written once and read back; database never stores a value at
# all, it generates and revokes one on every request.
resource "vault_mount" "kv" {
  path = "kv"
  type = "kv-v2"
}

resource "vault_mount" "database" {
  path = "database"
  type = "database"
}

# Postgres runs as one Nomad job per environment (dev/prod are two
# separate clusters, never federated), so there are 4 connections here,
# not 2 — one per (database, environment) pair. Each environment's
# connection reaches Postgres through that environment's own local
# Consul DNS resolver, since a single Vault process can't rely on plain
# hostname resolution to disambiguate two non-federated catalogs on its
# own — the resolver PORT is what picks the environment, not the name.
#
# Naming convention: production keeps the bare name, development gets a
# "-dev" suffix (postgres-dev, not dev-postgres) — applied consistently
# across every per-environment name in this module.
locals {
  postgres_consul_resolvers = {
    dev  = "127.0.0.1:8600"
    prod = "127.0.0.1:8601"
  }
}

resource "vault_database_secret_backend_connection" "postgres_metrics" {
  for_each      = toset(["dev", "prod"])
  backend       = vault_mount.database.path
  name          = each.key == "prod" ? "postgres-metrics" : "postgres-metrics-dev"
  allowed_roles = [each.key == "prod" ? "metrics-api" : "metrics-api-dev"]

  # verify_connection is intentionally false: this module can be
  # applied before Postgres itself has ever been deployed. Leaving
  # verification on would make an unrelated apply fail simply because
  # the database doesn't exist yet, rather than only failing the first
  # time a credential is actually requested against it.
  verify_connection = false

  postgresql {
    connection_url = "postgresql://{{username}}:{{password}}@${local.postgres_consul_resolvers[each.key]}/metrics?sslmode=disable"
    username        = "vault-admin"
    password        = random_password.vault_admin_db.result
  }
}

resource "vault_database_secret_backend_role" "metrics_api" {
  for_each = toset(["dev", "prod"])
  backend  = vault_mount.database.path
  name     = each.key == "prod" ? "metrics-api" : "metrics-api-dev"
  db_name  = vault_database_secret_backend_connection.postgres_metrics[each.key].name

  creation_statements = [
    "CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}';",
    "GRANT CONNECT ON DATABASE metrics TO \"{{name}}\";",
    # Postgres 15+ no longer grants CREATE on the public schema by
    # default — needed here for the application's own
    # CREATE TABLE IF NOT EXISTS on first startup.
    "GRANT CREATE ON SCHEMA public TO \"{{name}}\";",
    "GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA public TO \"{{name}}\";",
  ]
  default_ttl = 3600
  max_ttl     = 3600
}

resource "vault_database_secret_backend_connection" "postgres_monitoring" {
  for_each      = toset(["dev", "prod"])
  backend       = vault_mount.database.path
  name          = each.key == "prod" ? "postgres-monitoring" : "postgres-monitoring-dev"
  allowed_roles = [each.key == "prod" ? "monitoring" : "monitoring-dev"]
  verify_connection = false

  postgresql {
    connection_url = "postgresql://{{username}}:{{password}}@${local.postgres_consul_resolvers[each.key]}/monitoring?sslmode=disable"
    username        = "vault-admin"
    password        = random_password.vault_admin_db.result
  }
}

resource "vault_database_secret_backend_role" "monitoring" {
  for_each = toset(["dev", "prod"])
  backend  = vault_mount.database.path
  name     = each.key == "prod" ? "monitoring" : "monitoring-dev"
  db_name  = vault_database_secret_backend_connection.postgres_monitoring[each.key].name

  creation_statements = [
    "CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}';",
    "GRANT CONNECT ON DATABASE monitoring TO \"{{name}}\";",
    "GRANT CREATE ON SCHEMA public TO \"{{name}}\";",
    "GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA public TO \"{{name}}\";",
  ]
  default_ttl = 3600
  max_ttl     = 3600
}
