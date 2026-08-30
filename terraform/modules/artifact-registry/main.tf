locals {    
  # Flatten var.repository_iam from role -> {members, condition}
  # into individual (role, member) pairs for google_artifact_registry_repository_iam_member.
  repository_iam_flat = merge([
    for role, config in var.repository_iam : {
      for member in config.members :
      "${replace(role, "roles/artifactregistry.", "")}/${replace(replace(member, "serviceAccount:", ""), "user:", "")}" => {
        role      = role
        member    = member
        condition = config.condition
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

  kms_key_name    = var.storage_cmek
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
  for_each = local.repository_iam_flat

  project    = var.project_id
  location   = var.region
  repository = google_artifact_registry_repository.platform.name
  role       = each.value.role
  member     = each.value.member

  dynamic "condition" {
    for_each = each.value.condition != null ? [each.value.condition] : []
    content {
      title       = condition.value.title
      description = condition.value.description
      expression  = condition.value.expression
    }
  }
}