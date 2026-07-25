variable "gcp_project" {
  type = string
}

variable "octopus_address" {
  type    = string
  default = "https://octopus.platform.lefrancis.org"
}

variable "octopus_api_key" {
  type      = string
  sensitive = true
}
