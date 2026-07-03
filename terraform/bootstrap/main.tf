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






# GitHub runner SA — mgmt VM (same VM as Vault, same SA limit applies)
# Since the mgmt VM can only have one SA (vault-sa), the GitHub runner
# running on that VM inherits vault-sa's permissions. We grant
# Artifact Registry write to vault-sa so the runner can push images.
# This is a pragmatic tradeoff: the alternative is a separate runner VM.
# Clearly documented here so the permission is not mysterious.


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

resource "google_artifact_registry_repository_iam_member" "runner_push" {
  project    = var.project_id
  location   = var.region
  repository = google_artifact_registry_repository.platform.name
  role       = "roles/artifactregistry.writer"
  member     = module.sa_vault.member
}