locals {
  default_arifact_registry_iam = {
    "roles/artifactregistry.writer" = { 
        members = [] 
    }
    "roles/artifactregistry.reader" = { 
        members = [] 
    }
  }

  artifact_registry_iam = {
    "roles/artifactregistry.writer" = { 
        members = var.artifact_registry_creator_members 
    }
    "roles/artifactregistry.reader" = { 
        members = var.artifact_registry_viewer_members 
    }
  }

  iam_roles = merge(
    local.default_arifact_registry_iam,
    local.artifact_registry_iam,
    var.additional_artifact_registry_iam
  )

  iam_flat = flatten([
    for role, config in local.iam_roles : [
      for member in config.members : {
        role   = role
        member = member
      }
    ]
  ])
}

resource "google_artifact_registry_repository" "artifact_repo" {
  project       = var.project_id
  location      = var.region
  repository_id = var.repo_name
  format        = "DOCKER" # Change to MAVEN, NPM, etc. as needed
  description   = "Production artifact repository"

  # ── Security & Compliance ───────────────────────────────────────────────────
  # CMEK encryption for data-at-rest compliance
  kms_key_name = var.gcs_storage_key_id

  # ── Persistence ─────────────────────────────────────────────────────────────
  # Prevents accidental deletion by Terraform
  deletion_policy = "PREVENT"

  # ── Docker-Specific Settings ────────────────────────────────────────────────
  # Immutable tags prevent overwriting existing versions (Crucial for PROD)
  docker_config {
    immutable_tags = true
  }

  # ── Cost Management ─────────────────────────────────────────────────────────
  # Automatically keeps only the 20 most recent versions
  cleanup_policies {
    id     = "keep-recent-20"
    action = "KEEP"
    most_recent_versions {
      keep_count = 20
    }
  }

  # ── Labels ──────────────────────────────────────────────────────────────────
  labels = merge(
    {
      managed-by = "terraform"
      purpose    = "production-artifacts"
      team       = "platform"
    },
    var.additional_labels
  )
}



# ── IAM Bindings ──────────────────────────────────────────────────────────────
# Assigns IAM members to the roles on the repository.
resource "google_artifact_registry_repository_iam_member" "repo_iam" {
  for_each = {
    for idx, item in local.iam_flat : "${item.role}-${item.member}" => item
  }

  project    = var.project_id
  location   = google_artifact_registry_repository.artifact_repo.location
  repository = google_artifact_registry_repository.artifact_repo.name
  
  role       = each.value.role
  member     = each.value.member
}