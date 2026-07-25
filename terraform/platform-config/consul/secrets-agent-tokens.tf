# Pushes The 8 Flag-4 Tokens (4 Types x 2 Envs) To Secret Manager, Under
# The Exact Names The Startup Scripts Already Expect To Read At Boot.
#
# NOTE: verify `.id` is the correct attribute for the token's secret
# value on the hashicorp/consul provider version pinned in providers.tf
# — provider attribute naming for ACL token secrets has shifted across
# versions (SecretID vs id vs secret_id). Confirm against the provider's
# actual docs/schema before first apply; noting this rather than
# asserting it's certainly correct.

resource "google_secret_manager_secret_version" "consul_server_agent_token_dev" {
  secret      = "consul-server-agent-token-dev"
  secret_data = consul_acl_token.agent_dev.id
}

resource "google_secret_manager_secret_version" "consul_client_agent_token_dev" {
  secret      = "consul-client-agent-token-dev"
  secret_data = consul_acl_token.agent_dev.id # shared token — see cardinality note in acl-agent-tokens.tf
}

resource "google_secret_manager_secret_version" "nomad_server_consul_token_dev" {
  secret      = "nomad-server-consul-token-dev"
  secret_data = consul_acl_token.nomad_server_dev.id
}

resource "google_secret_manager_secret_version" "nomad_client_consul_token_dev" {
  secret      = "nomad-client-consul-token-dev"
  secret_data = consul_acl_token.nomad_client_dev.id
}

resource "google_secret_manager_secret_version" "consul_server_agent_token_prod" {
  secret      = "consul-server-agent-token-prod"
  secret_data = consul_acl_token.agent_prod.id
}

resource "google_secret_manager_secret_version" "consul_client_agent_token_prod" {
  secret      = "consul-client-agent-token-prod"
  secret_data = consul_acl_token.agent_prod.id
}

resource "google_secret_manager_secret_version" "nomad_server_consul_token_prod" {
  secret      = "nomad-server-consul-token-prod"
  secret_data = consul_acl_token.nomad_server_prod.id
}

resource "google_secret_manager_secret_version" "nomad_client_consul_token_prod" {
  secret      = "nomad-client-consul-token-prod"
  secret_data = consul_acl_token.nomad_client_prod.id
}
