# GitHub Actions OIDC — Avoids Any Long-Lived GitHub Secret Just To Reach
# Vault. The Self-Hosted Runner Lives On The Same Box As Vault, So This
# Is Purely About Not Storing A Standing Credential In GitHub, Not About
# Network Reachability.
resource "vault_jwt_auth_backend" "github" {
  path         = "jwt-github-actions"
  jwks_url     = "https://token.actions.githubusercontent.com/.well-known/jwks"
  bound_issuer = "https://token.actions.githubusercontent.com"
}

resource "vault_jwt_auth_backend_role" "github" {
  backend           = vault_jwt_auth_backend.github.path
  role_name         = "github-actions-ci"
  role_type         = "jwt"
  bound_audiences   = [var.github_oidc_audience]
  user_claim        = "repository"
  bound_claims_type = "glob"
  bound_claims = {
    repository = var.github_repository
    ref        = "refs/heads/main" # trunk-based, main branch only — matches CI/CD trigger scope
  }
  token_policies = [vault_policy.github_actions.name]
  token_ttl      = 900 # short-lived — a single CI run only
}
