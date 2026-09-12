
# Postgres runs as one Nomad job per environment (dev/prod are two
# separate clusters), so there are 4 connections here, one per (database, environment) pair.
#
# Vault itself has no local Consul agent (mgmt-vm's old dual dev+prod
# agent processes were removed in favor of traefik-internal), so it
# can't resolve postgres.service.consul on its own — and Postgres is
# scheduled onto whichever on-demand client node has room, so there's
# no static IP to hardcode either. Routing each connection through a
# dedicated TCP passthrough port on traefik-internal's dev-internal/
# prod-internal instances gets both problems solved at once: Traefik's
# own consulCatalog resolution finds the live allocation, the same way
# it already does for HTTP traffic.
#
# NOTE: this is the Terraform half only. traefik-internal's Ansible
# role doesn't have these two TCP entrypoints yet, and the Postgres
# Nomad job spec doesn't have the traefik.tcp.routers.* service tags
# to be discovered by them — both are a follow-up before this
# connection actually works end to end. Until then, verify_connection
# = false below means this module still applies cleanly, but no
# credential can actually be issued.

locals {
  postgres_traefik_endpoints = {
    dev  = "postgres-dev.platform.lefrancis.org:15432"
    prod = "postgres-prod.platform.lefrancis.org:15433"
  }
}

resource "vault_database_secret_backend_connection" "postgres_metrics" {
  for_each      = toset(["dev", "prod"])
  backend       = vault_mount.database.path
  name          = each.key == "prod" ? "${local.vault_consumers["metrics-api"].db_role}-prod" : "${local.vault_consumers["metrics-api"].db_role}-dev"
  allowed_roles = [each.key == "prod" ? "${local.vault_consumers["metrics-api"].db_role}-prod" : "${local.vault_consumers["metrics-api"].db_role}-dev"]

  # verify_connection is intentionally false: this module can be
  # applied before Postgres itself has ever been deployed. Leaving
  # verification on would make an unrelated apply fail simply because
  # the database doesn't exist yet, rather than only failing the first
  # time a credential is actually requested against it.
  verify_connection = false

  postgresql {
    connection_url = "postgresql://{{username}}:{{password}}@${local.postgres_traefik_endpoints[each.key]}/metrics?sslmode=disable"
    username        = "vault-admin"
    password        = random_password.vault_admin_db.result
  }
}

resource "vault_database_secret_backend_role" "metrics_api" {
  for_each = toset(["dev", "prod"])
  backend  = vault_mount.database.path
  name     = each.key == "prod" ? "${local.vault_consumers["metrics-api"].db_role}-prod" : "${local.vault_consumers["metrics-api"].db_role}-dev"
  db_name  = vault_database_secret_backend_connection.postgres_metrics[each.key].name

  creation_statements = [
    "CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}';",
    "GRANT CONNECT ON DATABASE metrics TO \"{{name}}\";",
    "GRANT CREATE ON SCHEMA public TO \"{{name}}\";",
    "GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA public TO \"{{name}}\";",
  ]
  default_ttl = 3600
  max_ttl     = 3600
}

resource "vault_database_secret_backend_connection" "postgres_monitoring" {
  for_each      = toset(["dev", "prod"])
  backend       = vault_mount.database.path
  name          = each.key == "prod" ? "${local.vault_consumers["nomad-sentinel"].db_role}-prod" : "${local.vault_consumers["nomad-sentinel"].db_role}-dev"
  allowed_roles = [each.key == "prod" ? "${local.vault_consumers["nomad-sentinel"].db_role}-prod" : "${local.vault_consumers["nomad-sentinel"].db_role}-dev"]
  verify_connection = false

  postgresql {
    connection_url = "postgresql://{{username}}:{{password}}@${local.postgres_traefik_endpoints[each.key]}/monitoring?sslmode=disable"
    username        = "vault-admin"
    password        = random_password.vault_admin_db.result
  }
}

resource "vault_database_secret_backend_role" "monitoring" {
  for_each = toset(["dev", "prod"])
  backend  = vault_mount.database.path
  name     = each.key == "prod" ? "${local.vault_consumers["nomad-sentinel"].db_role}-prod" : "${local.vault_consumers["nomad-sentinel"].db_role}-dev"
  db_name  = vault_database_secret_backend_connection.postgres_monitoring[each.key].name

  creation_statements = [
    "CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}';",
    "GRANT CONNECT ON DATABASE monitoring TO \"{{name}}\";",
    "GRANT CREATE ON SCHEMA public TO \"{{name}}\";",
    "GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA public TO \"{{name}}\";",
    "GRANT \"vault-admin\" TO \"{{name}}\";",
  ]
  default_ttl = 3600
  max_ttl     = 3600
}
