variable "gcp_project" {
  type = string
}

variable "nomad_token_dev" {
  type      = string
  sensitive = true
}

variable "nomad_token_prod" {
  type      = string
  sensitive = true
}

variable "nomad_cacert_dev" {
  type        = string
  description = "Path to dc-dev's CA cert file, written by scripts/pre-apply.sh (same 3-CA-by-environment file as Consul's)"
}

variable "nomad_cacert_prod" {
  type        = string
  description = "Path to dc-prod's CA cert file, written by scripts/pre-apply.sh"
}
