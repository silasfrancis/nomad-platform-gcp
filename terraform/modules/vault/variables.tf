variable "gcp_project_id" {
  type = string
}

variable "nomad_provisioned" {
  description = "Whether Nomad servers are up and serving JWKS. Set false to skip resources that depend on Nomad being reachable (e.g. JWT auth backends) until compute exists."
  type        = bool
  default     = true
}

variable "vault_vm_member" {
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
