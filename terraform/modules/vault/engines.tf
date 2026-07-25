# Secrets Engines

resource "vault_mount" "kv" {
  path = "kv"
  type = "kv-v2"
}

resource "vault_mount" "database" {
  path = "database"
  type = "database"
}

# Postgres Connection — metrics Database (metrics-api)
resource "vault_database_secret_backend_connection" "postgres_metrics" {
  backend       = vault_mount.database.path
  name          = "postgres-metrics"
  allowed_roles = ["dev-metrics-api", "prod-metrics-api"]

  postgresql {
    connection_url = "postgresql://{{username}}:{{password}}@${var.postgres_host}:5432/metrics?sslmode=disable"
    username        = "vault-root"
    password        = var.postgres_vault_root_password
  }
}

resource "vault_database_secret_backend_role" "metrics_api" {
  for_each = toset(["dev", "prod"])
  backend  = vault_mount.database.path
  name     = "${each.key}-metrics-api"
  db_name  = vault_database_secret_backend_connection.postgres_metrics.name

  creation_statements = [
    "CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}';",
    "GRANT CONNECT ON DATABASE metrics TO \"{{name}}\";",
    "GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA public TO \"{{name}}\";",
  ]
  default_ttl = 3600
  max_ttl     = 3600
}

# Postgres Connection — monitoring Database (nomad-sentinel / agent_anomalies)
#
# Same Postgres server as metrics, separate CREATE DATABASE database, per
# this session's two-database decision. Uses dynamic Vault-issued creds,
# matching metrics-api's pattern — this supersedes history.py's original
# docstring, which documented a static long-lived credential instead.
# history.py's comment needs updating to match; not yet done.
resource "vault_database_secret_backend_connection" "postgres_monitoring" {
  backend       = vault_mount.database.path
  name          = "postgres-monitoring"
  allowed_roles = ["dev-monitoring", "prod-monitoring"]

  postgresql {
    connection_url = "postgresql://{{username}}:{{password}}@${var.postgres_host}:5432/monitoring?sslmode=disable"
    username        = "vault-root"
    password        = var.postgres_vault_root_password
  }
}

resource "vault_database_secret_backend_role" "monitoring" {
  for_each = toset(["dev", "prod"])
  backend  = vault_mount.database.path
  name     = "${each.key}-monitoring"
  db_name  = vault_database_secret_backend_connection.postgres_monitoring.name

  creation_statements = [
    "CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}';",
    "GRANT CONNECT ON DATABASE monitoring TO \"{{name}}\";",
    "GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA public TO \"{{name}}\";",
  ]
  default_ttl = 3600
  max_ttl     = 3600
}
