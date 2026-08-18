# Create a dedicated service account for Vault to use as its master backend
resource "google_service_account" "vault_gcp_backend" {
  account_id   = "vault-gcp-backend"
  display_name = "Vault GCP Secrets Backend Master SA"
  project      = var.gcp_project_id
}

# Grant Vault the permissions it needs to manage service accounts and keys
resource "google_project_iam_member" "vault_gcp_backend_roles" {
  for_each = toset([
    "roles/iam.serviceAccountKeyAdmin",
    "roles/iam.serviceAccountAdmin"
  ])

  project = var.gcp_project_id
  role    = each.key
  member  = google_service_account.vault_gcp_backend.member
}

# Generate the JSON private key file for this service account
resource "google_service_account_key" "vault_gcp_backend_key" {
  service_account_id = google_service_account.vault_gcp_backend.name
}

# Decode the base64 key generated above and feed it to Vault
resource "vault_gcp_secret_backend" "gcp" {
  path        = "gcp"
  credentials = base64decode(google_service_account_key.vault_gcp_backend_key.private_key)
}

# Create the Roleset specifically for the Nomad Autoscaler per environment
resource "vault_gcp_secret_roleset" "nomad_autoscaler" {
  for_each = toset(["dev", "prod"])

  backend     = vault_gcp_secret_backend.gcp.path
  roleset     = "nomad-autoscaler-${each.value}"
  secret_type = "service_account_key"
  project     = var.gcp_project_id

  # Give the generated service account permissions to manage/view the MIGs 
  # and instance operations required for scaling clusters up and down
  binding {
    resource = "//cloudresourcemanager.googleapis.com/projects/${var.gcp_project_id}"
    roles = [
      "roles/compute.instanceAdmin.v1",
      "roles/compute.networkViewer"
    ]
  }
}
