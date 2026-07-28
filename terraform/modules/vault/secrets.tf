# Redis Password
resource "random_password" "redis" {
  for_each = toset(["dev", "prod"])
  length   = 32
  special  = false
}

resource "vault_kv_secret_v2" "cartservice_redis" {
  for_each = toset(["dev", "prod"])
  mount    = vault_mount.kv.path
  name     = "${each.key}/cartservice/redis"
  data_json = jsonencode({
    password = random_password.redis[each.key].result
  })
}

# nomad-sentinel(platform ai monitoring agent) config (gemini_api_key, slack_webhook_url) is seeded
# directly into Vault manually
#   vault kv put kv/dev/nomad-sentinel/config gemini_api_key=... slack_webhook_url=...
#   vault kv put kv/prod/nomad-sentinel/config gemini_api_key=... slack_webhook_url=...