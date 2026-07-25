variable "gcp_project" {
  type = string
}

variable "vault_address" {
  type    = string
  default = "https://vault.platform.lefrancis.org:8200"
}

variable "postgres_host" {
  type        = string
  description = "Private IP or Consul DNS name of the PostgreSQL Nomad job (e.g. postgresql.service.consul)"
}

variable "postgres_vault_root_password" {
  type        = string
  sensitive   = true
  description = "Password for the vault-root PostgreSQL superuser Vault uses to create/revoke dynamic roles. Sourced via TF_VAR_postgres_vault_root_password, never committed."
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
