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

variable "dns_suffix" {
  type        = string
  description = "e.g. \"platform.lefrancis.org.\" — trailing dot required by google_dns_record_set"
}

variable "records" {
  type        = map(string)
  description = "short hostname => target IP, e.g. { vault = \"10.2.1.x\" }"
}
