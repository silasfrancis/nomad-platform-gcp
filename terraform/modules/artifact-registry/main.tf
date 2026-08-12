locals {    
  artifact_registry_iam = {
    "roles/artifactregistry.writer" = {
      members = toset(concat(
        # Default members — always granted writer on this repo
        [],
        # Explicit members from tfvars — typically management-vm-sa (GitHub runner)
        var.artifact_registry_writer_members
      ))
    }
    "roles/artifactregistry.reader" = {
      members = toset(concat(
        # Default members — always granted reader on this repo
        [],
        # Explicit members from tfvars — typically nomad-client-sa (image pulls)
        var.artifact_registry_reader_members
      ))
    }
  }

  # Merge with any additional roles passed in via variable.
  # Allows adding roles like artifactregistry.repoAdmin without touching locals.
  artifact_registry_iam_merged = merge(
    local.artifact_registry_iam,
    var.additional_registry_iam
  )

  # Flatten to (role, member) pairs for for_each on iam_member resource.
  # Key format: "<role_short>/<member>" — readable in state file.
  artifact_registry_iam_flat = merge([
    for role, config in local.artifact_registry_iam_merged : {
      for member in config.members :
      "${replace(role, "roles/artifactregistry.", "")}/${replace(member, "serviceAccount:", "")}" => {
        role   = role
        member = member
      }
    }
  ]...)
}

resource "google_artifact_registry_repository" "platform" {
  project       = var.project_id
  location      = var.region
  repository_id = var.artifact_registry_repo
  format        = "DOCKER"
  description   = "Platform Docker images — nomad-sentinel, metrics-api, Online Boutique services (13 total)"

  kms_key_name = var.storage_cmek
  deletion_policy = "PREVENT"

  docker_config {
    immutable_tags = var.immutable_tags
  }

  cleanup_policies {
    id     = "keep-recent-versions"
    action = "KEEP"
    most_recent_versions {
      keep_count = var.image_keep_count
    }
  }

  labels = merge(
    {environment = "shared",
    purpose = "docker-images"},
    var.additional_labels
  )
}

resource "google_artifact_registry_repository_iam_member" "platform" {
  for_each = local.artifact_registry_iam_flat

  project    = var.project_id
  location   = var.region
  repository = google_artifact_registry_repository.platform.name
  role       = each.value.role
  member     = each.value.member
}