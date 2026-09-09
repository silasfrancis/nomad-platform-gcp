resource "google_project_iam_custom_role" "csi_disk_attach" {
  project     = var.project_id
  role_id     = "csiDiskAttacher"
  title       = "CSI Disk Attach/Detach"
  description = "Minimal permissions for the GCE PD CSI driver to attach/detach disks on client instances."
  permissions = [
    "compute.instances.attachDisk",
    "compute.instances.detachDisk",
    "compute.instances.get",
  ]
}

locals {
  service_accounts = {
    "nomad-server-sa-prod" = {
      display_name = "Nomad Server SA"
      description  = "Attached to control-plane VMs running Nomad Server and Consul Server."
      # Project-level roles assigned here provide baseline functionality
      # (e.g. logging, monitoring,Compute Engine instance discovery for
      # Nomad/Consul auto-join and Compute storage for persistent disks).
      #
      # Sensitive permissions (such as Secret Manager, Cloud Storage, KMS, and
      # other workload-specific access) are intentionally excluded from these
      # project-level roles and granted only on the specific resources that
      # require them, following the principle of least privilege.
      project_roles = [
        "roles/logging.logWriter",
        "roles/monitoring.metricWriter",
        "roles/compute.viewer"
      ]
    }
    "nomad-server-sa-dev" = {
      display_name = "Nomad Server SA"
      description  = "Attached to control-plane VMs running Nomad Server and Consul Server."
      project_roles = [
        "roles/logging.logWriter",
        "roles/monitoring.metricWriter",
        "roles/compute.viewer"
      ]
    }
    "nomad-client-sa-prod" = {
      display_name = "Nomad Client SA"
      description  = "Attached to worker VMs running Nomad Client and Consul Client."
      project_roles = [
        "roles/logging.logWriter",
        "roles/monitoring.metricWriter",
        "roles/compute.viewer",
        "roles/compute.storageAdmin",
        "roles/iam.serviceAccountUser",
        "projects/${var.project_id}/roles/csiDiskAttacher"
      ]
    }
    "nomad-client-sa-dev" = {
      display_name = "Nomad Client SA"
      description  = "Attached to worker VMs running Nomad Client and Consul Client."
      project_roles = [
        "roles/logging.logWriter",
        "roles/monitoring.metricWriter",
        "roles/compute.viewer",
        "roles/compute.storageAdmin",
        "roles/iam.serviceAccountUser",
        "projects/${var.project_id}/roles/csiDiskAttacher"
      ]
    }
    "management-vm-sa" = {
      display_name = "Management VM SA"
      description  = "Attached to mgmt VM. Covers Vault, GitHub runner, Octopus, Grafana, internal Traefik."
      project_roles = [
        "roles/logging.logWriter",
        "roles/monitoring.metricWriter",
      ]
    }
    "traefik-vm-sa-prod" = {
      display_name  = "Traefik VM SA (Prod)"
      description   = "Attached to mgmt VM. Covers Vault, GitHub runner, Octopus, Grafana, internal Traefik."
      project_roles = []
    }
    "traefik-vm-sa-dev" = {
      display_name  = "Traefik VM SA (Dev)"
      description   = "Attached to Prod Traefik VM."
      project_roles = []
    }
    "traefik-vm-sa-internal" = {
      display_name  = "Traefik VM SA (Internal)"
      description   = "Attached to Internal Traefik VM."
      project_roles = []
    }
    "packer-builder-sa" = {
      display_name = "Packer Builder SA"
      description  = "Used by Packer to build golden VM images (nomad-server, nomad-client, mgmt-vm). Attached to ephemeral build VMs only."
      project_roles = [
        "roles/compute.instanceAdmin.v1",
        "roles/compute.storageAdmin",
        "roles/iam.serviceAccountUser",
        "roles/iap.tunnelResourceAccessor",
        "roles/compute.networkViewer",
      ]
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

resource "google_service_account_iam_member" "this" {
  for_each = {
    for item in flatten([
      for sa_name, sa_config in local.service_accounts : [
        for member in var.service_account_iam_members : {
          key     = "${sa_name}/${member}"
          sa_name = sa_name
          member  = member
        }
      ]
    ]) : item.key => item
  }

  service_account_id = google_service_account.this[each.value.sa_name].id
  role                = "roles/iam.serviceAccountUser"
  member              = each.value.member
}

resource "google_project_iam_member" "roles" {
  for_each = local.service_account_roles_flat

  project = var.project_id
  role    = each.value.role
  member  = google_service_account.this[each.value.sa_name].member

  depends_on = [google_project_iam_custom_role.csi_disk_attach]
}