variable "gcp_project" {
  type = string
}

variable "nomad_address_dev" {
  type        = string
  description = "dev Nomad server address, reachable from wherever Vault runs (mgmt subnet) — used only to build the JWKS URL, not for API calls"
}

variable "nomad_address_prod" {
  type        = string
  description = "prod Nomad server address, same purpose as nomad_address_dev"
}

variable "github_oidc_audience" {
  type    = string
  default = "https://github.com/silasfrancis"
}

variable "github_repository" {
  type        = string
  description = "org/repo — bound in the GitHub OIDC role's claims so only workflows from this repo can authenticate"
  default     = "silasfrancis/nomad-platform-gcp"
}

variable "traefik_internal_address" {
  type        = string
  description = "traefik-internal's own internal FQDN or IP — see engines.tf for how it's used to reach Postgres in dev/prod via a dedicated TCP passthrough, now that mgmt-vm no longer runs its own local Consul agents to resolve postgres.service.consul directly."
}
