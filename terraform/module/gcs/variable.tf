variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "region" {
  description = "Primary GCP region for all resources"
  type        = string
}

variable "additional_labels" {
  type        = map(string)
  description = "Additional labels to apply to the repository."
  default     = {}
}

variable "project_number" {
  description = <<-EOT
    GCP project number — not the project ID.
    Required to construct GCP service agent email addresses for KMS IAM bindings.
    Find it: gcloud projects describe <project_id> --format='value(projectNumber)'
  EOT
  type        = string
}

variable "environment" {
  description = <<-EOT
    Environment label applied to resources as a label fallback.
    Bootstrap resources are shared across dev and prod so this defaults
    to "shared". Override per bucket in the buckets map if needed.
  EOT
  type        = string
  default     = "shared"
}

# ── KMS ──────────────────────────────────────────────────────────────────────

variable "storage_cmek" {
  description = <<-EOT
    Full resource ID of the KMS key used for storage encryption.
    Format: projects/<project>/locations/<region>/keyRings/<ring>/cryptoKeys/<key>
    Output from the kms module after bootstrap applies.
    Passed in after first apply or read from remote state in subsequent layers.
  EOT
  type        = string
  default     = ""
  # Default empty so bootstrap can create the key and bucket in one apply.
  # The bucket resource depends_on the KMS IAM binding so ordering is safe.
  # If you want to pass an existing key from a previous apply, set this.
}

# ── Buckets ───────────────────────────────────────────────────────────────────

variable "tfstate_bucket" {
  description = <<-EOT
    Name of the GCS bucket used for Terraform remote state.
    Created manually before bootstrap runs — Terraform cannot create
    its own state backend. After bootstrap applies, run:
      gcloud storage buckets update gs://<name> \
        --default-encryption-key=<gcs_storage key ID>
    to apply CMEK retroactively.
  EOT
  type        = string
}

variable "artifact_registry_repo" {
  description = "Name of the Artifact Registry Docker repository"
  type        = string
  default     = "platform"
}

variable "backup_retention_days" {
  description = <<-EOT
    Default number of days to retain objects across all buckets.
    Individual buckets override this via backup_retention_days in the buckets map.
  EOT
  type        = number
  default     = 30
}

# ── Bucket IAM members ────────────────────────────────────────────────────────
# These are passed as variables rather than hardcoded so that:
#   - SA emails (known only after bootstrap creates them) can be passed in
#   - Additional members can be added via tfvars without touching locals
#   - CI pipelines can inject members at apply time
#
# All default to empty list — no members are bound unless explicitly set.

variable "platform_artifacts_creator_members" {
  description = <<-EOT
    IAM members granted roles/storage.objectCreator on the platform-artifacts bucket.
    Typically: management-vm-sa (backup writes) and nomad-client-sa (pg_dump writes).
    Format: ["serviceAccount:x@project.iam.gserviceaccount.com"]
  EOT
  type        = list(string)
  default     = []
}

variable "platform_artifacts_viewer_members" {
  description = <<-EOT
    IAM members granted roles/storage.objectViewer on the platform-artifacts bucket.
    Typically: management-vm-sa (backup reads for restore).
    Format: ["serviceAccount:x@project.iam.gserviceaccount.com"]
  EOT
  type        = list(string)
  default     = []
}

variable "cicd_artifacts_creator_members" {
  description = <<-EOT
    IAM members granted roles/storage.objectCreator on the ci-cd-artifacts bucket.
    Typically: management-vm-sa (GitHub runner pushes build artifacts).
    Format: ["serviceAccount:x@project.iam.gserviceaccount.com"]
  EOT
  type        = list(string)
  default     = []
}

variable "cicd_artifacts_viewer_members" {
  description = <<-EOT
    IAM members granted roles/storage.objectViewer on the ci-cd-artifacts bucket.
    Typically: nomad-client-sa (client nodes read build artifacts).
    Format: ["serviceAccount:x@project.iam.gserviceaccount.com"]
  EOT
  type        = list(string)
  default     = []
}