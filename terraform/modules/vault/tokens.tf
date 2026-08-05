resource "vault_token" "vault_snapshot_token" {
  policies = [
    vault_policy.snapshot.name
  ]

  renewable = true
  no_parent = true

  ttl     = "720h"
  period  = 0
}

resource "google_secret_manager_secret_version" "vault_snapshot_token" {
  secret      = "vault-snapshot-token"
  secret_data = vault_token.vault_snapshot_token.client_token
}

resource "vault_token" "grafana_admin_token" {
  policies = [
    vault_policy.grafana_admin.name
  ]

  renewable = true
  no_parent = true

  ttl     = "720h"
  period  = 0
}

resource "google_secret_manager_secret_version" "grafana_admin_token" {
  secret      = "grafana-admin-token"
  secret_data = vault_token.vault_snapshot_token.client_token
}
