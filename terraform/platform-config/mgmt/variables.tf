variable "gcp_project" {
  type = string
}

variable "vault_address" {
  type        = string
  description = "Reached via traefik-internal's mgmt instance (scripts/open-tunnel.sh mgmt tunnels localhost:8443 there) — not a direct connection to mgmt-vm:8200 any more. No CACERT needed: Traefik terminates with a real Let's Encrypt cert."
  default     = "https://vault.platform.lefrancis.org:8443"
}

variable "octopus_address" {
  type    = string
  default = "https://octopus.platform.lefrancis.org:8443"
}

variable "traefik_internal_address" {
  type        = string
  description = "traefik-internal's own internal FQDN or IP (e.g. traefik-internal.ZONE.c.PROJECT.internal), reachable from mgmt subnet. Used only to build Vault's Postgres TCP-passthrough connection strings in modules/vault/engines.tf — this is server-to-server traffic on the VPC, unrelated to vault_address/octopus_address above, which are for the operator's own IAP-tunneled Terraform runs."
}

variable "octopus_api_key" {
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
