resource "nomad_acl_token" "nomad_snapshot" {
  name = "nomad-snapshot-${var.environment}"
  type = "management"
  #   Nomad docs explictly state "If you enabled ACLs, you must supply a
  #   management token in order to perform snapshot operations."
}

resource "google_secret_manager_secret_version" "nomad_snapshot_token" {
  secret      = "nomad-snapshot-token-${var.environment}"
  secret_data = nomad_acl_token_secret_id.nomad_snapshot.secret_id
}