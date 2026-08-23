variable "project_id" {
  type = string
}

variable "region" {
  type = string
}

variable "platform_tfstate_bucket" {
  type = string
}

variable "compute_tfstate_key" {
  type = string
}

variable "vault_address" {
  type        = string
  description = "Reached via traefik-internal's mgmt instance (scripts/open-tunnel.sh mgmt tunnels localhost:8443 there)."
  default     = "https://vault.platform.lefrancis.org:8443"
}

variable "vault_token" {
  type = string
  sensitive = true
}

variable "octopus_address" {
  type    = string
  description = "Reached via traefik-internal's mgmt instance (scripts/open-tunnel.sh mgmt tunnels localhost:8443 there)."
  default = "https://octopus.platform.lefrancis.org:8443"
}

variable "octopus_api_key" {
  type = string
}

variable "octopus_space_id" {
  type = string
  default = "Spaces-1"
}

variable "nomad_address_dev" {
  type = string
  default     = "https://nomad-dev.platform.lefrancis.org:8444"
}

variable "nomad_address_prod" {
  type = string
  default     = "https://nomad-prod.platform.lefrancis.org:8445"
}

variable "github_oidc_audience" {
  type    = string
  default = "https://github.com/silasfrancis"
}

variable "github_repository" {
  type    = string
  default = "silasfrancis/nomad-platform-gcp"
}
