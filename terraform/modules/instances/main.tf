# Static VMs
#
# Covers control-plane and fixed infrastructure: Nomad servers, the mgmt
# VM, and the three Traefik edge VMs. Nomad client workload nodes are NOT
# here — those are autoscaled MIGs, a separate module (nomad-client-mig),
# since MIGs need an instance template + region MIG + autoscaler rather
# than a plain google_compute_instance.

locals {
  disks_flat = merge([
      for inst_key, inst in var.instances : {
        for disk in try(inst.additional_disks, []) : "${inst_key}-${disk.name}" => merge(disk, {
          instance_key = inst_key
          zone         = inst.zone
        })
      }
    ]...)
  
  # Filter instances that need a static external IP reserved
  static_ips = {
    for k, v in var.instances : k => v 
    if try(v.external_ip, false) && try(v.static_external_ip, false)
  }
}

resource "google_compute_disk" "additional" {
  for_each = local.disks_flat

  project = var.project_id
  name    = each.key
  zone    = each.value.zone
  size    = each.value.size_gb
  type    = try(each.value.disk_type, "pd-balanced")

  disk_encryption_key {
    kms_key_self_link = var.disk_cmek_key
  }
}

# Reserve Static IPs dynamically for instances that need them
resource "google_compute_address" "static" {
  for_each = local.static_ips

  project      = var.project_id
  name         = "${each.key}-static-ip"
  address_type = "EXTERNAL"
  region       = replace(each.value.zone, "/-[a-z]$/", "")
}

resource "google_compute_instance" "this" {
  for_each = var.instances

  project      = var.project_id
  name         = each.key
  zone         = each.value.zone
  machine_type = each.value.machine_type

  tags   = each.value.tags
  labels = each.value.labels

  boot_disk {
    initialize_params {
      image = each.value.boot_disk_image
      size  = each.value.boot_disk_size_gb
      type  = each.value.boot_disk_type
    }
    kms_key_self_link = var.disk_cmek_key
  }

  dynamic "attached_disk" {
    for_each = { for k, v in local.disks_flat : k => v if v.instance_key == each.key }
    iterator = ad
    content {
      source            = google_compute_disk.additional[ad.key].self_link
      device_name       = ad.value.name
      kms_key_self_link = var.disk_cmek_key
      mode              = "READ_WRITE"
    }
  }
  
  network_interface {
    subnetwork = each.value.subnetwork

    dynamic "access_config" {
      for_each = each.value.external_ip ? [1] : []
      content {
        # If static_external_ip is true, bind the reserved address. Otherwise, leave empty for ephemeral.
        nat_ip = each.value.static_external_ip ? google_compute_address.static[each.key].address : null
      }
    }
  }

  service_account {
    email  = each.value.service_account_email
    scopes = each.value.service_account_scopes
  }

  metadata = merge(
    each.value.environment != null ? {
          env = each.value.environment
        } : {},

    contains(["dev", "prod"], try(each.value.environment, "")) ? {
      datacenter       = each.value.environment == "dev" ? "dc-dev" : "dc-prod"
      bootstrap_expect = each.value.environment == "prod" ? 3 : 1
    } : {},

    each.value.startup_script != "" ? { startup-script = each.value.startup_script } : {},
    each.value.spot && each.value.shutdown_script != "" ? { shutdown-script = each.value.shutdown_script } : {},
  )

  allow_stopping_for_update = true

}