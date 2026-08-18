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
  description = "Vault Operator token (Created in ansible/playbooks/vault-init.yaml and can be gotten from gcp secret - vault-operator-token)"
}

variable "octopus_address" {
  type    = string
  description = "Reached via traefik-internal's mgmt instance (scripts/open-tunnel.sh mgmt tunnels localhost:8443 there)."
  default = "https://octopus.platform.lefrancis.org:8443"
}


variable "octopus_api_key" {
  type      = string
  sensitive = true 
  description = "Octopus deploy API key (Created in ansible/playbooks/mgmt.yaml and can be gotten from gcp secret - octopus-admin-api-key)"
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
