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
# Four tiers, split by who actually reads a secret rather than by vague
# sensitivity:
#   root     — write-once bootstrap material, essentially archival after
#              initial setup. Human-only (platform_admin_email).
#   operator — ongoing admin tokens, but read only by whoever runs
#              terraform/platform-config or manages Vault directly.
#              Human-only, never a VM.
#   mgmt     — ongoing secrets whose sole consumer is management-vm-sa.
#   scoped   — heterogeneous per-node/per-service consumers (PKI leaf
#              material, Traefik's per-env tokens) — always empty at the
#              tier level, every secret in this tier carries its own
#              explicit iam block in var.secrets below.

locals {
  nomad_server_dev_member  = module.service_account.service_accounts["nomad-server-sa-dev"].member
  nomad_server_prod_member = module.service_account.service_accounts["nomad-server-sa-prod"].member
  nomad_client_dev_member  = module.service_account.service_accounts["nomad-client-sa-dev"].member
  nomad_client_prod_member = module.service_account.service_accounts["nomad-client-sa-prod"].member
  packer_builder_member    = module.service_account.service_accounts["packer-builder-sa"].member
  management_vm_member     = module.service_account.service_accounts["management-vm-sa"].member
  traefik_vm_dev_member  = module.service_account.service_accounts["traefik-vm-sa-dev"].member
  traefik_vm_prod_member = module.service_account.service_accounts["traefik-vm-sa-prod"].member

  # Every Nomad-Cluster-Adjacent SA — Used By The Three Secrets Genuinely
  # Uniform Across All Five (Consul CA, Nomad CA, Vault's Cert).
  all_scoped_members = [
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

  root_tier_accessor_members     = []
  operator_tier_accessor_members = ["user:${var.platform_admin_email}"]
  mgmt_tier_accessor_members     = [local.management_vm_member]
  # Deliberately Empty Every Scoped Secret Below Carries Its Own Precise iam Block Instead.
  scoped_tier_accessor_members = []

  secrets = {
    # Uniform Across All Five Cluster SAs
    "consul-ca-cert" = {
      labels = { purpose = "consul", tier = "scoped" }
      iam = {
        "roles/secretmanager.secretAccessor" = { members = local.all_scoped_members }
      }
    }
    "nomad-ca-cert" = {
      labels = { purpose = "nomad", tier = "scoped" }
      iam = {
        "roles/secretmanager.secretAccessor" = { members = local.all_scoped_members }
      }
    }
    "vault-cert" = {
      labels = { purpose = "vault", tier = "scoped" }
      iam = {
        # Also Needed By management-vm-sa (Configures Vault's Own
        # Listener), Not Just The Cluster Nodes Trusting It.
        "roles/secretmanager.secretAccessor" = {
          members = concat(local.all_scoped_members, [local.management_vm_member])
        }
      }
    }

    # CA Private Keys — Human-Only, No VM Ever Needs These
    "consul-ca-key" = {
      labels = { purpose = "consul", tier = "root" }
      iam = {
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

    # Nomad Server/Client Leaf Certs
    "nomad-server-cert" = {
      labels = { purpose = "nomad", tier = "scoped" }
      iam = {
        "roles/secretmanager.secretAccessor" = {
          members = [local.nomad_server_dev_member, local.nomad_server_prod_member]
        }
      }
    }
    "nomad-server-tls-key" = {
      labels = { purpose = "nomad", tier = "scoped" }
      iam = {
        "roles/secretmanager.secretAccessor" = {
          members = [local.nomad_server_dev_member, local.nomad_server_prod_member]
        }
      }
    }
    "nomad-client-cert" = {
      labels = { purpose = "nomad", tier = "scoped" }
      iam = {
        "roles/secretmanager.secretAccessor" = {
          members = [local.nomad_client_dev_member, local.nomad_client_prod_member, local.packer_builder_member]
        }
      }
    }
    "nomad-client-tls-key" = {
      labels = { purpose = "nomad", tier = "scoped" }
      iam = {
        "roles/secretmanager.secretAccessor" = {
          members = [local.nomad_client_dev_member, local.nomad_client_prod_member, local.packer_builder_member]
        }
      }
    }

    # Consul Server/Client Certs + Gossip Keys
    "consul-server-cert-dev" = {
      labels = { purpose = "consul", tier = "scoped", environment = "dev" }
      iam = { "roles/secretmanager.secretAccessor" = { members = [local.nomad_server_dev_member] } }
    }
    "consul-server-tls-key-dev" = {
      labels = { purpose = "consul", tier = "scoped", environment = "dev" }
      iam = { "roles/secretmanager.secretAccessor" = { members = [local.nomad_server_dev_member] } }
    }
    "consul-server-cert-prod" = {
      labels = { purpose = "consul", tier = "scoped", environment = "prod" }
      iam = { "roles/secretmanager.secretAccessor" = { members = [local.nomad_server_prod_member] } }
    }
    "consul-server-tls-key-prod" = {
      labels = { purpose = "consul", tier = "scoped", environment = "prod" }
      iam = { "roles/secretmanager.secretAccessor" = { members = [local.nomad_server_prod_member] } }
    }

    "consul-client-cert-dev" = {
      labels = { purpose = "consul", tier = "scoped", environment = "dev" }
      iam = {
        "roles/secretmanager.secretAccessor" = {
          members = [local.nomad_client_dev_member, local.packer_builder_member]
        }
      }
    }
    "consul-client-tls-key-dev" = {
      labels = { purpose = "consul", tier = "scoped", environment = "dev" }
      iam = { "roles/secretmanager.secretAccessor" = { members = [local.nomad_client_dev_member] } }
    }
    "consul-client-cert-prod" = {
      labels = { purpose = "consul", tier = "scoped", environment = "prod" }
      iam = {
        "roles/secretmanager.secretAccessor" = {
          members = [local.nomad_client_prod_member, local.packer_builder_member]
        }
      }
    }
    "consul-client-tls-key-prod" = {
      labels = { purpose = "consul", tier = "scoped", environment = "prod" }
      iam = { "roles/secretmanager.secretAccessor" = { members = [local.nomad_client_prod_member] } }
    }

    "consul-gossip-key-dev" = {
      labels = { purpose = "consul", tier = "scoped", environment = "dev" }
      iam = {
        "roles/secretmanager.secretAccessor" = {
          members = [local.nomad_server_dev_member, local.nomad_client_dev_member]
        }
      }
    }
    "consul-gossip-key-prod" = {
      labels = { purpose = "consul", tier = "scoped", environment = "prod" }
      iam = {
        "roles/secretmanager.secretAccessor" = {
          members = [local.nomad_server_prod_member, local.nomad_client_prod_member]
        }
      }
    }

    "vault-tls-key" = {
      labels = { purpose = "vault", tier = "mgmt" }
      iam = {
        "roles/secretmanager.secretAccessor" = { members = [local.management_vm_member] }
      }
    }

    "consul-traefik-token-dev" = {
      labels = { purpose = "traefik", tier = "scoped", environment = "dev" }
      iam    = { "roles/secretmanager.secretAccessor" = { members = [local.traefik_vm_dev_member] } }
    }
    "consul-traefik-token-prod" = {
      labels = { purpose = "traefik", tier = "scoped", environment = "prod" }
      iam    = { "roles/secretmanager.secretAccessor" = { members = [local.traefik_vm_prod_member] } }
    }
  }
}