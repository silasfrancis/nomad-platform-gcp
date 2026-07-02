# bootstrap/main.tf
#
# Project-wide GCP infrastructure primitives.
# Applied once — not per-environment. Dev and prod share these resources.
#
# Apply order:
#   1. terraform apply (this file)
#   2. gcloud storage buckets update gs://<tfstate_bucket> \
#        --default-encryption-key=<gcs_storage key ID>
#   3. Proceed to terraform/network

# ── GCP APIs ─────────────────────────────────────────────────────────────────
#
# cloudresourcemanager.googleapis.com must be enabled manually before this
# runs — it is the API that enables other APIs and cannot enable itself.
# Run once: gcloud services enable cloudresourcemanager.googleapis.com
#
# disable_on_destroy = false: disabling an API in use causes cascading
# failures across all resources that depend on it. Safer to leave enabled
# and clean up manually if the project is decommissioned.

locals {

  # ── APIs ───────────────────────────────────────────────────────────────────
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
  # ── KMS keyrings ──────────────────────────────────────────────────────────
  kms_keyrings = {
    "vault-unseal" = {
      keys = {
        "vault-unseal-key" = {
          purpose         = "ENCRYPT_DECRYPT"
          rotation_period = "31536000s"
        }
      }
    }
    "platform-storage" = {
      keys = {
        "gcs-storage" = {
          purpose         = "ENCRYPT_DECRYPT"
          rotation_period = "7776000s"
        }
        "persistent-disk" = {
          purpose         = "ENCRYPT_DECRYPT"
          rotation_period = "7776000s"
        }
      }
    }
  }

  # ── Service accounts ───────────────────────────────────────────────────────
  service_accounts = {
    "nomad-server-sa" = {
      display_name  = "Nomad Server SA"
      description   = "Attached to Nomad server VMs. Logging and monitoring only."
      project_roles = [
        "roles/logging.logWriter",
        "roles/monitoring.metricWriter",
      ]
    }
    "nomad-client-sa" = {
      display_name  = "Nomad Client SA"
      description   = "Attached to Nomad client MIG nodes."
      project_roles = [
        "roles/artifactregistry.reader",
        "roles/logging.logWriter",
        "roles/monitoring.metricWriter",
      ]
    }
    "management-vm-sa" = {
      display_name  = "Management VM SA"
      description   = "Attached to mgmt VM. Covers Vault, GitHub runner, Octopus, Grafana, internal Traefik."
      project_roles = [
        "roles/logging.logWriter",
        "roles/monitoring.metricWriter",
      ]
    }
  }

  # ── Resource-scoped IAM bindings ───────────────────────────────────────────
  # These can't go in the module because they reference other resources
  # (bucket, registry) that are created in this same file.
  # Expressed as locals for clarity — the actual resources still need
  # to be declared separately since for_each on IAM members is straightforward.

  # KMS key-level bindings
  kms_key_iam_bindings = {
    "gcs-storage-agent" = {
      keyring = "platform-storage"
      key     = "gcs-storage"
      role    = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
      member  = "serviceAccount:service-${var.project_number}@gs-project-accounts.iam.gserviceaccount.com"
    }
    "compute-disk-agent" = {
      keyring = "platform-storage"
      key     = "persistent-disk"
      role    = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
      member  = "serviceAccount:service-${var.project_number}@compute-system.iam.gserviceaccount.com"
    }
    "vault-unseal" = {
      keyring = "vault-unseal"
      key     = "vault-unseal-key"
      role    = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
      member  = "management-vm-sa" # resolved at resource level
    }
  }

  # GCS bucket IAM bindings
  bucket_iam_bindings = {
    "mgmt-vm-writer" = {
      sa   = "management-vm-sa"
      role = "roles/storage.objectCreator"
    }
    "mgmt-vm-reader" = {
      sa   = "management-vm-sa"
      role = "roles/storage.objectViewer"
    }
    "nomad-client-writer" = {
      sa   = "nomad-client-sa"
      role = "roles/storage.objectCreator"
    }
    "nomad-client-reader" = {
      sa   = "nomad-client-sa"
      role = "roles/storage.objectViewer"
    }
  }

  # Artifact Registry IAM bindings
  registry_iam_bindings = {
    "mgmt-vm-push" = {
      sa   = "management-vm-sa"
      role = "roles/artifactregistry.writer"
    }
    "nomad-client-pull" = {
      sa   = "nomad-client-sa"
      role = "roles/artifactregistry.reader"
    }
  }
}

resource "google_project_service" "apis" {
  for_each = toset(local.apis)

  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}





# ── Service accounts ──────────────────────────────────────────────────────────
#
# One SA per VM — GCP hard limit. Each SA is scoped to the minimum
# permissions its VM needs. Specific resource-scoped bindings (e.g.
# GCS bucket IAM) are defined inline below rather than as project roles.

# Nomad server SA — Nomad server VMs only
# Minimal permissions: logging + monitoring. Servers run no workloads
# and don't need Artifact Registry or GCS access.
module "sa_nomad_server" {
  source = "../modules/service-account"

  project_id   = var.project_id
  account_id   = "nomad-server-sa"
  display_name = "Nomad Server SA"
  description  = "Attached to Nomad server VMs. Logging and monitoring only — servers run no workloads."

  project_roles = [
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
  ]
}

# Nomad client SA — all Nomad client MIG nodes
# Needs Artifact Registry to pull Docker images for scheduled jobs,
# GCS write for pg_dump backup periodic jobs,
# logging + monitoring for observability.
module "sa_nomad_client" {
  source = "../modules/service-account"

  project_id   = var.project_id
  account_id   = "nomad-client-sa"
  display_name = "Nomad Client SA"
  description  = "Attached to Nomad client MIG nodes. Pulls images from Artifact Registry, writes pg_dump backups to GCS."

  project_roles = [
    "roles/artifactregistry.reader",
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
  ]
}

# Vault SA — mgmt VM
# Needs KMS for auto-unseal, GCS for backup writes/reads.
# GCS bindings are resource-scoped below (not project-level) so Vault
# can only access the platform-artifacts bucket, not all GCS buckets.
module "sa_vault" {
  source = "../modules/service-account"

  project_id   = var.project_id
  account_id   = "vault-sa"
  display_name = "Vault SA"
  description  = "Attached to mgmt VM. KMS auto-unseal for Vault, GCS backup writes for Vault/Consul/Octopus/Grafana snapshots."

  project_roles = [
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
  ]
  # KMS and GCS permissions are resource-scoped below — not project-level
}

# GitHub runner SA — mgmt VM (same VM as Vault, same SA limit applies)
# Since the mgmt VM can only have one SA (vault-sa), the GitHub runner
# running on that VM inherits vault-sa's permissions. We grant
# Artifact Registry write to vault-sa so the runner can push images.
# This is a pragmatic tradeoff: the alternative is a separate runner VM.
# Clearly documented here so the permission is not mysterious.

# Artifact Registry — push permission for GitHub runner (on vault-sa's mgmt VM)
resource "google_artifact_registry_repository_iam_member" "runner_push" {
  project    = var.project_id
  location   = var.region
  repository = google_artifact_registry_repository.platform.name
  role       = "roles/artifactregistry.writer"
  member     = module.sa_vault.member
}

# ── KMS IAM — Vault SA → vault-unseal key ────────────────────────────────────
#
# vault-sa needs encrypt/decrypt on the vault-unseal key specifically.
# This is a key-level binding, not a project-level role, so Vault's SA
# cannot use any other KMS key in the project.



# ── GCS — platform-artifacts bucket ──────────────────────────────────────────
#
# One bucket for all operational backups, separated by prefix:
#   vault-snapshots/dev/  vault-snapshots/prod/
#   consul-snapshots/dev/ consul-snapshots/prod/
#   pg-backups/dev/       pg-backups/prod/
#   sql-backups/dev/      sql-backups/prod/
#
# Single lifecycle rule: delete objects older than backup_retention_days.
# CMEK with gcs-storage key.
# uniform_bucket_level_access = true: disables per-object ACLs,
# enforces IAM-only access — security best practice.

resource "google_storage_bucket" "platform_artifacts" {
  project                     = var.project_id
  name                        = var.artifacts_bucket
  location                    = var.region
  uniform_bucket_level_access = true
  force_destroy               = false # never accidentally delete backup data

  encryption {
    default_kms_key_name = module.kms_platform_storage.key_ids["gcs-storage"]
  }

  lifecycle_rule {
    condition {
      age = var.backup_retention_days
    }
    action {
      type = "Delete"
    }
  }

  versioning {
    enabled = false # backups are complete snapshots, versioning adds cost with no benefit
  }

  depends_on = [google_kms_crypto_key_iam_member.gcs_storage_agent]
}

# GCS IAM — vault-sa can write and read backups (resource-scoped, not project-level)
resource "google_storage_bucket_iam_member" "vault_sa_artifacts_writer" {
  bucket = google_storage_bucket.platform_artifacts.name
  role   = "roles/storage.objectCreator"
  member = module.sa_vault.member
}

resource "google_storage_bucket_iam_member" "vault_sa_artifacts_reader" {
  bucket = google_storage_bucket.platform_artifacts.name
  role   = "roles/storage.objectViewer"
  member = module.sa_vault.member
}

# GCS IAM — nomad-client-sa can write pg_dump backups from client nodes
resource "google_storage_bucket_iam_member" "nomad_client_artifacts_writer" {
  bucket = google_storage_bucket.platform_artifacts.name
  role   = "roles/storage.objectCreator"
  member = module.sa_nomad_client.member
}

resource "google_storage_bucket_iam_member" "nomad_client_artifacts_reader" {
  bucket = google_storage_bucket.platform_artifacts.name
  role   = "roles/storage.objectViewer"
  member = module.sa_nomad_client.member
}

# ── Artifact Registry ─────────────────────────────────────────────────────────
#
# Single Docker repository for all platform images:
#   europe-west1-docker.pkg.dev/<project>/platform/nomad-sentinel:<sha>
#   europe-west1-docker.pkg.dev/<project>/platform/metrics-api:<sha>
#   europe-west1-docker.pkg.dev/<project>/platform/<boutique-service>:<sha>
#
# Images are tagged with git SHA by GitHub Actions CI — never with
# 'latest' in production to ensure deployments are always traceable
# to a specific commit.

resource "google_artifact_registry_repository" "platform" {
  project       = var.project_id
  location      = var.region
  repository_id = var.artifact_registry_repo
  format        = "DOCKER"
  description   = "Platform Docker images — nomad-sentinel, metrics-api, Online Boutique services"

  depends_on = [google_project_service.apis]
}

# Artifact Registry — nomad-client-sa can pull images to run Nomad Docker jobs
resource "google_artifact_registry_repository_iam_member" "nomad_client_pull" {
  project    = var.project_id
  location   = var.region
  repository = google_artifact_registry_repository.platform.name
  role       = "roles/artifactregistry.reader"
  member     = module.sa_nomad_client.member
}
