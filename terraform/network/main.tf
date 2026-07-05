# Single global VPC, subnets, firewall rules, Cloud NAT, and the private
# DNS zone. Not workspaced — one apply covers both dev and prod, since the
# VPC and firewall rules are project-wide by design (subnet isolation,
# not separate VPCs, per architecture doc section 1.1).
#
# Apply order:
#   1. terraform apply (this file)
#   2. Proceed to terraform/compute


#add remote state
locals {
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

# Cloud DNS

module "dns" {
  source             = "../modules/dns"
  project_id         = var.project_id
  network_self_link  = module.vpc.network_self_link
  dns_name           = "platform.lefrancis.org."
  labels             = local.labels
}

# Logging — Custom Bucket For VPC Flow Logs
#
# Flow logs (enabled on prod subnets only, see modules/vpc) get their own
# Cloud Logging bucket with 7-day retention instead of the project's
# _Default 30-day bucket, and are excluded from _Default so they aren't
# stored (and billed) twice.

module "logging" {
  source     = "../modules/logging"
  project_id = var.project_id
  region     = var.region
  storage-cmek = ""
}
