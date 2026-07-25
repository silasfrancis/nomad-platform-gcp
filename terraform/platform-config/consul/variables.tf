variable "gcp_project" {
  type = string
}

variable "consul_token_dev" {
  type      = string
  sensitive = true
}

variable "consul_token_prod" {
  type      = string
  sensitive = true
}

variable "consul_cacert_dev" {
  type        = string
  description = "Path to dc-dev's CA cert file, written by scripts/pre-apply.sh"
}

variable "consul_cacert_prod" {
  type        = string
  description = "Path to dc-prod's CA cert file, written by scripts/pre-apply.sh"
}
