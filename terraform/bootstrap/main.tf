# Project-wide GCP infrastructure primitives.
# Applied once — not per-environment. Dev and prod share these resources.
#
# Apply order:
#   1. terraform apply (this file)
#   2. gcloud storage buckets update gs://<tfstate_bucket> \
#        --default-encryption-key=<gcs_storage key ID>
#   3. Proceed to terraform/network

# GCP APIs
#
# cloudresourcemanager.googleapis.com must be enabled manually before this
# runs — it is the API that enables other APIs and cannot enable itself.
# Run once: gcloud services enable cloudresourcemanager.googleapis.com
#
# disable_on_destroy = false: disabling an API in use causes cascading
# failures across all resources that depend on it. Safer to leave enabled
# and clean up manually if the project is decommissioned.

locals {
  apis = [
    "compute.googleapis.com",                # VMs, disks, networking, MIGs
    "iam.googleapis.com",                    # service accounts, IAM bindings
    "storage.googleapis.com",               # GCS buckets
    "artifactregistry.googleapis.com",       # Docker image registry
    "cloudkms.googleapis.com",              # KMS keyrings and keys
    "secretmanager.googleapis.com",          # Vault root token + recovery keys storage
    "oslogin.googleapis.com",               # OS Login for SSH via IAP
    "iap.googleapis.com",                   # Identity-Aware Proxy (SSH + UI tunnels)
    "logging.googleapis.com",               # Cloud Logging
    "monitoring.googleapis.com",            # Cloud Monitoring
    "securitycenter.googleapis.com",         # GCP Security Command Center (Standard tier)
    "dns.googleapis.com",                   # Cloud DNS (public + private zones)
  ]

  project = "nomad-platform-gcp"
  labels = {
    "environment" = "shared"
    "managed-by" = "terraform"
  }
}

resource "google_project_service" "apis" {
  for_each = toset(local.apis)

  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

# OS Login
#
# Project-wide: Replaces static SSH keys with Google-managed IAM authentication.
# All VMs (present and future) will require IAM roles for access.

resource "google_compute_project_metadata_item" "os_login" {
  project = var.project_id
  key     = "enable-oslogin"
  value   = "TRUE"
}

# Service Accounts 
# Creates GCP Service Accounts for VM Identities (Management VM, Nomad Server VM, Nomad Client VM, Traefik VM)
# and Packer Image Builder

module "service_account" {
  source = "../modules/service-account"

  project_id = var.project_id
}

# KMS

module "kms" {
  source = "../modules/kms"

  project_id = var.project_id
  project_number = var.project_number
  region = var.region
  crypto_key_members = {
    
    "platform/storage-cmek" = [
      "serviceAccount:service-${var.project_number}@gs-project-accounts.iam.gserviceaccount.com",
      "serviceAccount:service-${var.project_number}@gcp-sa-artifactregistry.iam.gserviceaccount.com",
      "serviceAccount:service-${var.project_number}@gcp-sa-secretmanager.iam.gserviceaccount.com",
      "serviceAccount:service-${var.project_number}@gcp-sa-logging.iam.gserviceaccount.com",
      "serviceAccount:cmek-${var.project_id}@gcp-sa-logging.iam.gserviceaccount.com",
    ]

    "platform/disk-cmek" = [
      "serviceAccount:service-${var.project_number}@compute-system.iam.gserviceaccount.com",
    ]

    "vault-unseal/vault-unseal-cmek" = [
      module.service_account.service_accounts["management-vm-sa"].member
    ]
  }
}

# GCS Buckets

module "gcs_bucket" {
  source = "../modules/gcs"

  project_id = var.project_id
  region     = var.region
  additional_labels = local.labels
  environment = var.environment
  storage_cmek = module.kms.kms_keys["storage-cmek"].id
  platform_artifacts_creator_members = [
    module.service_account.service_accounts["management-vm-sa"].member,
    module.service_account.service_accounts["nomad-client-sa"].member
  ]
  platform_artifacts_viewer_members = [
    module.service_account.service_accounts["management-vm-sa"].member,
    module.service_account.service_accounts["nomad-client-sa"].member
  ]
  cicd_artifacts_creator_members = [
    module.service_account.service_accounts["management-vm-sa"].member
  ]
  cicd_artifacts_viewer_members = [
    module.service_account.service_accounts["management-vm-sa"].member
  ]

}

# Artifact Registry

module "artifact_registry" {
  source = "../modules/artifact-registry"

  project_id = var.project_id
  region     = var.region
  artifact_registry_repo = local.project
  storage_cmek = module.kms.kms_keys["storage-cmek"].id
  artifact_registry_writer_members = [
    module.service_account.service_accounts["management-vm-sa"].member
  ]
  artifact_registry_reader_members = [
    module.service_account.service_accounts["management-vm-sa"].member,
    module.service_account.service_accounts["nomad-client-sa"].member
  ]
  additional_registry_iam = {}
  immutable_tags = true
  additional_labels = local.labels

}

# Secret Manager
#
# Root and admin tier accessors both resolve to management-vm-sa for now —
# a deliberate cost tradeoff, since the mgmt VM already hosts Vault, Octopus,
# the GitHub runner, and Grafana. Root tokens are used once during initial
# setup regardless, so the shared SA doesn't add meaningful risk here.

module "secrets" {
  source       = "../modules/secret-manager"
  project_id   = var.project_id
  storage_cmek = module.kms.kms_keys["storage-cmek"].id

  labels = local.labels

  # Only net-new secrets go here. Do NOT repeat keys from default_secrets —
  # the module's validation block will fail the plan if you do.
  secrets = {
    # "new-service-token" = {
    #   labels = { purpose = "new-service", tier = "admin" }
    # }
  }

  # This implementation was done to ensure that in the case where a newly created vm or service account
  # will need acceess to a GCP secret, it can be plugged in here. However, service accounts within the original
  # project scope will not need access to any GCP secret.
  # No access will be given to any service account created in this bootstrap module, 
  # because no vm requires access to any of these secrets (root/admin secrets) and 
  # application/runtime secrets will be accessed via hashicorp vault
  root_tier_accessor_members  = []
  admin_tier_accessor_members = []
  app_tier_accessor_members   = []
}
