variable "gcp_project" {
  type = string
}

variable "consul_token" {
  type      = string
  sensitive = true
}

variable "nomad_token" {
  type      = string
  sensitive = true
}
