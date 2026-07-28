# Postgres Admin-Tier Credentials
#
# Generated once by Terraform, never typed by hand. Two separate
# passwords with two separate jobs:
#
#   - postgres_superuser: launches the Postgres container itself
#     (POSTGRES_USER/POSTGRES_PASSWORD). Used exactly once, in the
#     init script, to create the vault-admin role and both databases.
#     Nothing else in the system ever authenticates as this role.
#
#   - vault_admin_db: the role Vault itself authenticates as for every
#     database connection above. Created BY the superuser during init,
#     granted CREATEROLE plus ownership of both databases — never the
#     superuser account itself. Keeping Vault's own identity separate
#     from the instance's bootstrap credential means the two can be
#     rotated and revoked independently of each other.
#
# Shared across dev and prod: each environment is a fully separate
# Postgres instance on a fully separate cluster, so reusing the same
# password value doesn't share any actual blast radius between them —
# it's the same convenience as reusing one Terraform module, not one
# shared secret protecting two real things at once.
resource "random_password" "postgres_superuser" {
  length  = 32
  special = false
}

resource "random_password" "vault_admin_db" {
  length  = 32
  special = false
}

# Written to Vault KV so the Postgres Nomad job's own Workload Identity
# role can read both values for its init script. Vault's own connection
# resources reference random_password.vault_admin_db.result directly
# (same module, same state) rather than reading this entry back.
resource "vault_kv_secret_v2" "postgres_admin" {
  mount = vault_mount.kv.path
  name  = "shared/postgres/admin"
  data_json = jsonencode({
    superuser_password   = random_password.postgres_superuser.result
    vault_admin_password = random_password.vault_admin_db.result
  })
}
