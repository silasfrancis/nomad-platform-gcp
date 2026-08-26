variable "project_id" {
  type = string
}

variable "region" {
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
