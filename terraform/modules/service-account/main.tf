locals {
  service_accounts = {
    "nomad-server-sa" = {
      display_name  = "Nomad Server SA"
      description   = "Attached to Nomad server VMs. Logging and monitoring only."
      # Project-level roles assigned here provide baseline functionality (e.g., logging and monitoring).
      # Sensitive permissions (e.g., storage or KMS access) are deliberately excluded from these 
      # project-level assignments and will be applied at the specific resource level to 
      # strictly enforce the principle of least privilege.
      project_roles = [
        "roles/logging.logWriter",
        "roles/monitoring.metricWriter",
      ]
    }
    "nomad-client-sa" = {
      display_name  = "Nomad Client SA"
      description   = "Attached to Nomad client MIG nodes."
      project_roles = [
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
    "traefik-vm-sa" = {
      display_name  = "Management VM SA"
      description   = "Attached to mgmt VM. Covers Vault, GitHub runner, Octopus, Grafana, internal Traefik."
      project_roles = []
    }
  }
  # Flattened map for project-level IAM bindings
  # Format: "sa_name/role" = { sa_name, role }
  service_account_roles_flat = merge([
    for sa_name, sa_config in local.service_accounts : {
      for role in sa_config.project_roles :
      "${sa_name}/${role}" => {
        sa_name = sa_name
        role    = role
      }
    }
  ]...)
}

resource "google_service_account" "this" {
  for_each     = local.service_accounts
  project      = var.project_id
  account_id   = each.key
  display_name = each.value.display_name
  description  = each.value.description
}

resource "google_project_iam_member" "roles" {
  for_each = local.service_account_roles_flat

  project = var.project_id
  role    = each.value.role
  member  = google_service_account.this[each.value.sa_name].member
}