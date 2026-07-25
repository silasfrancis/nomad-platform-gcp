variable "gcp_project" {
  type = string
}

variable "consul_token" {
  type      = string
  sensitive = true
}

variable "consul_cacert" {
  type = string
}

variable "nomad_token" {
  type      = string
  sensitive = true
}

variable "nomad_cacert" {
  type = string
}
