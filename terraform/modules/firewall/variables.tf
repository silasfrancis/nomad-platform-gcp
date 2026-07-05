variable "project_id" {
  type = string
}

variable "network_self_link" {
  description = "Self-link of the VPC these rules attach to."
  type        = string
}

variable "subnet_cidrs" {
  description = "Map of subnet name to CIDR. Used for both source_ranges and destination_ranges — destinations are scoped by subnet CIDR membership rather than instance tags, so a rule's reach can't drift out of sync with a missed or mistyped tag on a VM/MIG template in compute/."
  type        = map(string)
}
