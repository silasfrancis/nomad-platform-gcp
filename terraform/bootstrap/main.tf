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
    module.service_account.service_accounts["nomad-client-sa-prod"].member,
    module.service_account.service_accounts["nomad-client-sa-dev"].member,
  ]
  platform_artifacts_viewer_members = [
    module.service_account.service_accounts["management-vm-sa"].member,
    module.service_account.service_accounts["nomad-client-sa-prod"].member,
    module.service_account.service_accounts["nomad-client-sa-dev"].member,
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
    module.service_account.service_accounts["nomad-client-sa-prod"].member,
    module.service_account.service_accounts["nomad-client-sa-dev"].member,
  ]
  additional_registry_iam = {}
  immutable_tags = true
  additional_labels = local.labels

}

# Secret Manager
#
# Root and platform tier accessors both resolve to management-vm-sa — a
# deliberate cost tradeoff, since the mgmt VM already hosts Vault, Octopus,
# the GitHub runner, and Grafana. Root tokens are used once during initial
# setup regardless, so the shared SA doesn't add meaningful risk here.
#
# Cluster-tier PKI secrets are defined entirely in var.secrets below, not
# default_secrets — each carries its own precise iam block, since consumer
# sets vary per secret (all five cluster SAs, server-only, client-only, or
# a single environment) in a way a flat tier grant can't safely express.

locals {
  nomad_server_dev_member  = module.service_account.service_accounts["nomad-server-sa-dev"].member
  nomad_server_prod_member = module.service_account.service_accounts["nomad-server-sa-prod"].member
  nomad_client_dev_member  = module.service_account.service_accounts["nomad-client-sa-dev"].member
  nomad_client_prod_member = module.service_account.service_accounts["nomad-client-sa-prod"].member
  packer_builder_member    = module.service_account.service_accounts["packer-builder-sa"].member
  management_vm_member     = module.service_account.service_accounts["management-vm-sa"].member

  # Every Nomad-Cluster-Adjacent SA — Used By The Three Secrets Genuinely
  # Uniform Across All Five (Consul CA, Nomad CA, Vault's Cert).
  all_cluster_members = [
    local.nomad_server_dev_member,
    local.nomad_server_prod_member,
    local.nomad_client_dev_member,
    local.nomad_client_prod_member,
    local.packer_builder_member,
  ]
}

module "secrets" {
  source       = "../modules/secret-manager"
  project_id   = var.project_id
  storage_cmek = module.kms.kms_keys["storage-cmek"].id

  labels = local.labels

  root_tier_accessor_members     = [local.management_vm_member]
  platform_tier_accessor_members = [local.management_vm_member]
  # Deliberately Empty — See variables.tf's Description. Every Cluster
  # Secret Below Carries Its Own Precise iam Block Instead.
  cluster_tier_accessor_members = []

  secrets = {
    # --- Uniform Across All Five Cluster SAs ---
    "consul-ca-cert" = {
      labels = { purpose = "consul", tier = "cluster" }
      iam = {
        "roles/secretmanager.secretAccessor" = { members = local.all_cluster_members }
      }
    }
    "nomad-ca-cert" = {
      labels = { purpose = "nomad", tier = "cluster" }
      iam = {
        "roles/secretmanager.secretAccessor" = { members = local.all_cluster_members }
      }
    }
    "vault-cert" = {
      labels = { purpose = "vault", tier = "cluster" }
      iam = {
        # Also Needed By management-vm-sa (Configures Vault's Own
        # Listener), Not Just The Cluster Nodes Trusting It.
        "roles/secretmanager.secretAccessor" = {
          members = concat(local.all_cluster_members, [local.management_vm_member])
        }
      }
    }

    # --- CA Private Keys — Human-Only, No VM Ever Needs These ---
    "consul-ca-key" = {
      labels = { purpose = "consul", tier = "root" }
      iam = {
        # TODO: Confirm var.platform_admin_email Is Declared In Bootstrap's
        # Root Variables — Referenced Elsewhere For The IAP/OS Login
        # Grants In compute/main.tf.
        "roles/secretmanager.secretAccessor" = {
          members = ["user:${var.platform_admin_email}"]
        }
      }
    }
    "nomad-ca-key" = {
      labels = { purpose = "nomad", tier = "root" }
      iam = {
        "roles/secretmanager.secretAccessor" = {
          members = ["user:${var.platform_admin_email}"]
        }
      }
    }

    # --- Nomad Server/Client Leaf Certs — Scoped To The Role That Uses Them ---
    "nomad-server-cert" = {
      labels = { purpose = "nomad", tier = "cluster" }
      iam = {
        "roles/secretmanager.secretAccessor" = {
          members = [local.nomad_server_dev_member, local.nomad_server_prod_member]
        }
      }
    }
    "nomad-server-key" = {
      labels = { purpose = "nomad", tier = "cluster" }
      iam = {
        "roles/secretmanager.secretAccessor" = {
          members = [local.nomad_server_dev_member, local.nomad_server_prod_member]
        }
      }
    }
    "nomad-client-cert" = {
      labels = { purpose = "nomad", tier = "cluster" }
      iam = {
        "roles/secretmanager.secretAccessor" = {
          members = [local.nomad_client_dev_member, local.nomad_client_prod_member, local.packer_builder_member]
        }
      }
    }
    "nomad-client-key" = {
      labels = { purpose = "nomad", tier = "cluster" }
      iam = {
        "roles/secretmanager.secretAccessor" = {
          members = [local.nomad_client_dev_member, local.nomad_client_prod_member, local.packer_builder_member]
        }
      }
    }

    # --- Consul Server/Client Certs + Gossip Keys — Scoped To Role AND Environment ---
    "consul-server-cert-dev" = {
      labels = { purpose = "consul", tier = "cluster", environment = "dev" }
      iam = { "roles/secretmanager.secretAccessor" = { members = [local.nomad_server_dev_member] } }
    }
    "consul-server-key-dev" = {
      labels = { purpose = "consul", tier = "cluster", environment = "dev" }
      iam = { "roles/secretmanager.secretAccessor" = { members = [local.nomad_server_dev_member] } }
    }
    "consul-server-cert-prod" = {
      labels = { purpose = "consul", tier = "cluster", environment = "prod" }
      iam = { "roles/secretmanager.secretAccessor" = { members = [local.nomad_server_prod_member] } }
    }
    "consul-server-key-prod" = {
      labels = { purpose = "consul", tier = "cluster", environment = "prod" }
      iam = { "roles/secretmanager.secretAccessor" = { members = [local.nomad_server_prod_member] } }
    }

    "consul-client-cert-dev" = {
      labels = { purpose = "consul", tier = "cluster", environment = "dev" }
      iam = {
        "roles/secretmanager.secretAccessor" = {
          members = [local.nomad_client_dev_member, local.packer_builder_member]
        }
      }
    }
    "consul-client-key-dev" = {
      labels = { purpose = "consul", tier = "cluster", environment = "dev" }
      iam = { "roles/secretmanager.secretAccessor" = { members = [local.nomad_client_dev_member] } }
    }
    "consul-client-cert-prod" = {
      labels = { purpose = "consul", tier = "cluster", environment = "prod" }
      iam = {
        "roles/secretmanager.secretAccessor" = {
          members = [local.nomad_client_prod_member, local.packer_builder_member]
        }
      }
    }
    "consul-client-key-prod" = {
      labels = { purpose = "consul", tier = "cluster", environment = "prod" }
      iam = { "roles/secretmanager.secretAccessor" = { members = [local.nomad_client_prod_member] } }
    }

    "consul-gossip-key-dev" = {
      labels = { purpose = "consul", tier = "cluster", environment = "dev" }
      iam = {
        "roles/secretmanager.secretAccessor" = {
          members = [local.nomad_server_dev_member, local.nomad_client_dev_member]
        }
      }
    }
    "consul-gossip-key-prod" = {
      labels = { purpose = "consul", tier = "cluster", environment = "prod" }
      iam = {
        "roles/secretmanager.secretAccessor" = {
          members = [local.nomad_server_prod_member, local.nomad_client_prod_member]
        }
      }
    }
  }
}
