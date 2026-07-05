variable "project_id" {
  type = string
}

variable "region" {
  type = string
}

variable "network_id" {
  type = string
}

variable "nat_subnet_self_links" {
  description = "Self-links of subnets that need outbound internet via NAT (private subnets only — public subnets have direct public IPs and don't need this)."
  type        = list(string)
}
