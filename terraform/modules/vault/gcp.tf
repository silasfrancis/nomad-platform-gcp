resource "vault_gcp_secret_backend" "gcp" {
  path = "gcp"
}

# Grant Vault's VM the permissions it needs to manage service accounts and keys
resource "google_project_iam_member" "vault_gcp_backend_roles" {
  for_each = toset([
    "roles/iam.serviceAccountKeyAdmin",
    "roles/iam.serviceAccountAdmin"
  ])

  project = var.gcp_project_id
  role    = each.key
  member  = var.vault_vm_member
}

resource "google_service_account" "nomad_autoscaler" {
  for_each     = toset(["dev", "prod"])
  account_id   = "nomad-autoscaler-${each.key}"
  display_name = "Nomad Autoscaler ${each.key}"
  project      = var.gcp_project_id
}

resource "google_project_iam_member" "nomad_autoscaler_roles" {
  for_each = {
    for pair in setproduct(["dev", "prod"],
      ["roles/compute.instanceAdmin.v1",
      "roles/compute.networkViewer"]) :
    "${pair[0]}-${pair[1]}" => pair
  }

  project = var.gcp_project_id
  role    = each.value[1]
  member  = google_service_account.nomad_autoscaler[each.value[0]].member
}

resource "vault_gcp_secret_impersonated_account" "nomad_autoscaler" {
  for_each             = toset(["dev", "prod"])
  backend              = vault_gcp_secret_backend.gcp.path
  impersonated_account = "nomad-autoscaler-${each.key}"
  service_account_email = google_service_account.nomad_autoscaler[each.key].email
  token_scopes          = ["https://www.googleapis.com/auth/cloud-platform"]
  ttl                   = "3600"
}
