module "vault" {
  source = "../modules/vault"

  gcp_project                   = var.gcp_project
  postgres_host                 = var.postgres_host
  postgres_vault_root_password  = var.postgres_vault_root_password
  nomad_address_dev             = var.nomad_address_dev
  nomad_address_prod            = var.nomad_address_prod
  github_oidc_audience          = var.github_oidc_audience
  github_repository             = var.github_repository
}

# NOTE: dev/ and prod/ must each have been applied at least once
# before this module's first apply — it reads octopus-deploy-token-
# {dev,prod} from Secret Manager, written by nomad/'s ACL token
# resources in each environment. See root README's "Apply order".
module "octopus" {
  source = "../modules/octopus"

  gcp_project = var.gcp_project
}
