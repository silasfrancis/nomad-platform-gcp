# modules/service-account/main.tf
#
# Creates a GCP service account and binds IAM roles to it at project level.
#
# GCP notes:
#   - One SA per VM is the hard GCP limit — a VM cannot have more than
#     one attached service account.
#   - Roles are bound at project level here. For tighter scoping (e.g.
#     storage.objectCreator on a specific bucket only), use
#     google_storage_bucket_iam_member in the caller instead of passing
#     a project-level role here.
#   - account_id must be 6-30 characters, lowercase letters, digits,
#     and hyphens only.

resource "google_service_account" "this" {
  project      = var.project_id
  account_id   = var.account_id
  display_name = var.display_name
  description  = var.description
}

resource "google_project_iam_member" "roles" {
  for_each = toset(var.project_roles)

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.this.email}"
}
