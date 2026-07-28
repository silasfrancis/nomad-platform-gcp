# GitHub Actions OIDC Authentication
#
# Lets the CI runner exchange a short-lived GitHub-issued identity
# token for Vault access, scoped to one specific repository and branch,
# with no long-lived credential ever stored in GitHub itself.
resource "vault_jwt_auth_backend" "github_actions" {
  path               = "jwt-github-actions"
  oidc_discovery_url = "https://token.actions.githubusercontent.com"
  bound_issuer       = "https://token.actions.githubusercontent.com"
}

resource "vault_jwt_auth_backend_role" "github_actions" {
  backend           = vault_jwt_auth_backend.github_actions.path
  role_name         = "github-actions-ci"
  role_type         = "jwt"
  bound_audiences   = [var.github_oidc_audience]
  user_claim        = "repository"
  bound_claims_type = "glob"
  bound_claims = {
    repository = var.github_repository
    ref        = "refs/heads/main"
  }
  token_policies = [vault_policy.github_actions.name]
  token_ttl      = 900
}
