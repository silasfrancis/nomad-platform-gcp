variable "gcp_project_id" {
  type = string
}

variable "nomad_provisioned" {
  description = "Whether Nomad servers are up and serving JWKS. Set false to skip resources that depend on Nomad being reachable (e.g. JWT auth backends) until compute exists."
  type        = bool
  default     = true
}

variable "nomad_environments" {
  type    = list(string)
  default = ["dev", "prod"]
}

variable "nomad_addresses" {
  type = map(string)

  validation {
    condition = alltrue([
      for env in var.nomad_environments :
      contains(keys(var.nomad_addresses), env)
    ])

    error_message = "nomad_addresses must contain an address for every nomad environment."
  }
}

variable "vault_vm_member" {
  type = string
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
