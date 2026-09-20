# Single global VPC, subnets, firewall rules, Cloud NAT, and the private
# DNS zone. Not workspaced — one apply covers both dev and prod, since the
# VPC and firewall rules are project-wide by design (subnet isolation,
# not separate VPCs, per architecture doc section 1.1).
#
# Apply order:
#   1. terraform apply (this file)
#   2. Proceed to terraform/compute

 
locals {
  bootstrap = null

  labels = {
    "environment" = "shared"
    "managed-by"  = "terraform"
  }
}

# VPC & Subnets

module "vpc" {
  source       = "../modules/vpc"
  project_id   = var.project_id
  region       = var.region
  network_name = "nomad-platform"
  labels       = local.labels
}

# Firewall Rules

module "firewall" {
  source             = "../modules/firewall"
  project_id         = var.project_id
  network_self_link  = module.vpc.network_self_link

  subnet_cidrs = {
    for name, subnet in module.vpc.subnets : name => subnet.ip_cidr_range
  }
}

# Cloud NAT

module "nat" {
  source     = "../modules/nat"
  project_id = var.project_id
  region     = var.region
  network_id = module.vpc.network_id

  nat_subnet_self_links = [
    module.vpc.subnets["subnet-mgmt"].self_link,
    module.vpc.subnets["subnet-dev-private"].self_link,
    module.vpc.subnets["subnet-prod-private"].self_link,
  ]
}

# Logging — Configurable Log Buckets
#
# Add a new entry to var.log_buckets (module input, or edit the module's
# own default in variables.tf) to create another bucket — sink + _Default
# exclusion generated automatically per entry. All buckets share
# storage-cmek unless an entry overrides it.

module "logging" {
  source     = "../modules/logging"
  project_id = var.project_id
  region     = var.region

  default_cmek_key            = local.bootstrap.kms_keys["platform/storage-cmek"].id

    # Add more here as new logging needs come up, e.g.:
    # "secret-access" = {
    #   location       = optional(string)
    #   retention_days = 30
    #   filter         = "resource.type=\"audited_resource\" AND protoPayload.serviceName=\"secretmanager.googleapis.com\""
    #   description = ""
    #   cmek_key       = optional(string)
    # }
}

module "internal_dns" {
  source            = "../modules/dns"
  project_id        = var.project_id
  network_self_link = module.vpc.network_self_link

}