variable "project_id" {
  type = string
}

variable "network_self_link" {
  description = "VPC self-link this private zone is visible to."
  type        = string
}

variable "dns_name" {
  description = "Root of the private zone, must end with a trailing dot."
  type        = string
  default     = "platform.lefrancis.org."
}

variable "labels" {
  type    = map(string)
  default = {}
}
