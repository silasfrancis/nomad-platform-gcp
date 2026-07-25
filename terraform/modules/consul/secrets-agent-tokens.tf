# Pushes This Environment's 4 Flag-4 Tokens To Secret Manager, Under The
# Exact Names The Startup Scripts Expect.
#
# NOTE: verify `.id` is the correct attribute for the token's secret
# value on the hashicorp/consul provider version pinned in versions.tf
# before first apply — provider attribute naming for ACL token secrets
# has shifted across versions (SecretID vs id vs secret_id).

resource "google_secret_manager_secret_version" "consul_server_agent_token" {
  secret      = "consul-server-agent-token-${var.environment}"
  secret_data = consul_acl_token.agent.id
}

resource "google_secret_manager_secret_version" "consul_client_agent_token" {
  secret      = "consul-client-agent-token-${var.environment}"
  secret_data = consul_acl_token.agent.id # shared token — see acl-agent-tokens.tf
}

resource "google_secret_manager_secret_version" "nomad_server_consul_token" {
  secret      = "nomad-server-consul-token-${var.environment}"
  secret_data = consul_acl_token.nomad_server.id
}

resource "google_secret_manager_secret_version" "nomad_client_consul_token" {
  secret      = "nomad-client-consul-token-${var.environment}"
  secret_data = consul_acl_token.nomad_client.id
}
