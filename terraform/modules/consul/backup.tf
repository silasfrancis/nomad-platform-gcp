resource "consul_acl_policy" "consul_snapshot" {
  name = "consul-snapshot-${var.environment}"
  rules = <<-EOT
    operator = "write"
    acl      = "write"
  EOT
}

resource "consul_acl_token" "consul_snapshot" {
  description = "Consul snapshot token — dc-${var.environment}"
  policies    = [consul_acl_policy.consul_snapshot.name]
}

data "consul_acl_token_secret_id" "consul_snapshot" {
  accessor_id = consul_acl_token.consul_snapshot.id
}

resource "vault_kv_secret_v2" "consul_snapshot_token" {
  mount    = "kv"
  name     = "${var.environment}/backup/consul-token"
  data_json = jsonencode({
    token = "${data.consul_acl_token_secret_id.consul_snapshot.secret_id}"
  })
}

resource "google_secret_manager_secret_version" "consul_snapshot_token" {
  secret      = "consul-snapshot-token-${var.environment}"
  secret_data = data.consul_acl_token_secret_id.consul_snapshot.secret_id
}
