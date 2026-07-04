locals {

  # ── Artifact Registry IAM ─────────────────────────────────────────────────
  # Uses concat to merge default + var members per role — same pattern
  # as KMS and bucket IAM so the merge behaviour is consistent and explicit.
  #
  # default members: empty — no project-wide defaults for registry access.
  # Add project-wide members here if all repos should share a common reader.
  #
  # Per-role members come from variables so SA emails (known after bootstrap
  # creates them) can be passed in via tfvars without touching locals.
  # Additional roles beyond writer/reader go in var.additional_registry_iam.

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

# ── Artifact Registry repository ──────────────────────────────────────────────

resource "google_artifact_registry_repository" "platform" {
  project       = var.project_id
  location      = var.region
  repository_id = var.artifact_registry_repo
  format        = "DOCKER"
  description   = "Platform Docker images — nomad-sentinel, metrics-api, Online Boutique services (13 total)"

  kms_key_name = var.storage_cmek

  # PREVENT: refuse terraform destroy on this resource.
  # Images are reproducible from source but rebuilding all 13 services
  # takes time — don't make it easy to accidentally wipe the registry.
  deletion_policy = "PREVENT"

  docker_config {
    # immutable_tags: once pushed, a tag cannot be overwritten.
    # Safe for SHA-tagged images (CI never pushes the same SHA twice).
    # Set to false if you ever need to update a floating tag like "latest".
    immutable_tags = var.immutable_tags
  }

  # Keep the 20 most recent versions per image name.
  # 20 versions × 13 services = up to 260 images retained.
  # Older images are deleted automatically — no manual cleanup needed.
  # Adjust keep_count if storage costs become a concern.
  cleanup_policies {
    id     = "keep-recent-versions"
    action = "KEEP"
    most_recent_versions {
      keep_count = var.image_keep_count
    }
  }

  labels = merge(
    local.bucket_defaults.labels, # managed-by, team from shared defaults
    {
      environment = "shared"      # registry serves both dev and prod
      purpose     = "docker-images"
    },
    var.additional_labels
  )

  depends_on = [google_project_service.apis]
}

# ── Artifact Registry IAM ─────────────────────────────────────────────────────
# iam_member (not iam_binding) — additive, does not remove members added
# outside Terraform. Appropriate for a registry where GCP may add internal
# service accounts and CI tools may add their own bindings.

resource "google_artifact_registry_repository_iam_member" "platform" {
  for_each = local.artifact_registry_iam_flat

  project    = var.project_id
  location   = var.region
  repository = google_artifact_registry_repository.platform.name
  role       = each.value.role
  member     = each.value.member
}