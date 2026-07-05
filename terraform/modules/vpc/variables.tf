variable "project_id" {
  description = "GCP project ID."
  type        = string
}

variable "region" {
  description = "Region for regional subnets."
  type        = string
}

variable "network_name" {
  description = "Name of the single global VPC."
  type        = string
  default     = "nomad-platform"
}

variable "labels" {
  description = "Common labels applied where supported (subnets support labels via resource, network does not)."
  type        = map(string)
  default     = {}
}
