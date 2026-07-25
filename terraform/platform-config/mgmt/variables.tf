variable "gcp_project" {
  type = string
}

variable "vault_address" {
  type    = string
  default = "https://vault.platform.lefrancis.org:8200"
}

variable "octopus_address" {
  type    = string
  default = "https://octopus.platform.lefrancis.org"
}

variable "octopus_api_key" {
  type      = string
  sensitive = true
}

variable "postgres_host" {
  type = string
}

variable "postgres_vault_root_password" {
  type      = string
  sensitive = true
}

variable "nomad_address_dev" {
  type = string
}

variable "nomad_address_prod" {
  type = string
}

variable "github_oidc_audience" {
  type    = string
  default = "https://github.com/silasfrancis"
}

variable "github_repository" {
  type    = string
  default = "silasfrancis/nomad-platform-gcp"
}
