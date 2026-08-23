# Secrets Engines
#
# Static secrets (kv), dynamic database credentials (database), and GCP
# Compute credentials live in separate mounts, since they're managed very
# differently — kv holds values written once and read back; database never
# stores a value at all, it generates and revokes one on every request;
# compute generates short-lived GCP service-account keys on demand.
resource "vault_mount" "kv" {
  path = "kv"
  type = "kv-v2"
}

resource "vault_mount" "database" {
  path = "database"
  type = "database"
}

resource "vault_gcp_secret_backend" "gcp" {
  path = "gcp"
}