locals {
  compute = data.terraform_remote_state.compute.outputs
}

module "vault" {
  source = "../../modules/vault"

  gcp_project_id             = var.project_id
  nomad_address_dev        = var.nomad_address_dev
  nomad_address_prod       = var.nomad_address_prod
  github_oidc_audience     = var.github_oidc_audience
  github_repository        = var.github_repository
}

# NOTE: dev/ and prod/ must each have been applied at least once
# before this module's first apply — it reads octopus-deploy-token-
# {dev,prod} from Secret Manager, written by nomad/'s ACL token
# resources in each environment. See root README's "Apply order".
module "octopus" {
  source = "../../modules/octopus"

  gcp_project_id         = var.project_id
  nomad_address_dev   = var.nomad_address_dev
  nomad_address_prod  = var.nomad_address_prod

  # Traefik ip and entry points - only needed for prometheus scrape
  # and can be applied manually from the Octopus deploy UI if VMS are not yet setup
  # Refer to ansible/roles/traefik/defaults/main.yaml for configuration references
  # Public
  traefik_public_ip_dev  = try(local.compute.instances["traefik-dev"].external_ip, "0.0.0.0")
  traefik_public_ip_prod = try(local.compute.instances["traefik-prod"].external_ip, "0.0.0.0")
  traefik_public_port_dev = "8082"
  traefik_public_port_prod = "8082"

  # Internal
  traefik_internal_ip_dev = try(local.compute.instances["traefik-internal"].internal_ip, "0.0.0.0")
  traefik_internal_ip_prod = try(local.compute.instances["traefik-internal"].internal_ip, "0.0.0.0")
  traefik_internal_port_dev = "8082"
  traefik_internal_port_prod = "8083"
}
