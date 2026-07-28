# Postgres Admin-Tier Credentials
#
# Two passwords, two different jobs:
#   - postgres_superuser: POSTGRES_USER/POSTGRES_PASSWORD for the
#     container's own bootstrap. Used exactly once, in the init script,
#     to create vault-admin + both databases. Dormant after that —
#     nothing else in this system ever authenticates as this role.
#   - vault_admin_db: the role Vault itself authenticates as, for both
#     Postgres connections (metrics + monitoring, dev + prod). Created
#     BY the superuser during init, granted CREATEROLE + ownership of
#     both databases.

resource "random_password" "postgres_superuser" {
  length  = 32
  special = false
}

resource "random_password" "vault_admin_db" {
  length  = 32
  special = false
}

# Written to Vault KV, readable ONLY by the Postgres Nomad job's own
# Workload Identity role (needs both values for its init script's
# template stanza — the superuser password to launch the container,
# vault_admin_db's password to actually create that role in SQL).

resource "vault_kv_secret_v2" "postgres_admin" {
  mount = vault_mount.kv.path
  name  = "shared/postgres/admin"
  data_json = jsonencode({
    superuser_password = random_password.postgres_superuser.result
    vault_admin_password = random_password.vault_admin_db.result
  })
}
