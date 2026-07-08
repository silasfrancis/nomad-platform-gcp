# Static VMs (Non-Autoscaled)
#
# Covers control-plane and fixed infrastructure: Nomad servers, the mgmt
# VM, and the two Traefik edge VMs. Nomad client workload nodes are NOT
# here — those are autoscaled MIGs, a separate module (nomad-client-mig),
# since MIGs need an instance template + region MIG + autoscaler rather
# than a plain google_compute_instance.
#
# None of these are ever Spot (per architecture doc 1.3 — server quorum
# and public ingress can't tolerate preemption), so scheduling is left at
# GCP's standard defaults (on_host_maintenance = MIGRATE, automatic
# restart) rather than configured explicitly.


locals {
  disks_flat = merge([
    for inst_key, inst in var.instances : {
      for disk in inst.additional_disks : "${inst_key}-${disk.name}" => merge(disk, {
        instance_key = inst_key
        zone         = inst.zone
      })
    }
  ]...)
}

resource "google_compute_disk" "additional" {
  for_each = local.disks_flat

  project = var.project_id
  name    = each.key
  zone    = each.value.zone
  size    = each.value.size_gb
  type    = each.value.disk_type

  disk_encryption_key {
    kms_key_self_link = var.disk_cmek_key
  }
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
      image = var.boot_disk_image
      size  = each.value.boot_disk_size_gb
      type  = "pd-balanced"
    }
    kms_key_self_link = var.disk_cmek_key
  }

  # One attached_disk block per entry in this instance's additional_disks —
  # filtered out of the flattened map by instance_key.
  dynamic "attached_disk" {
    for_each = {
      for k, v in local.disks_flat : k => v if v.instance_key == each.key
    }
    content {
      source = google_compute_disk.additional[attached_disk.key].id
    }
  }

  network_interface {
    subnetwork = each.value.subnetwork

    dynamic "access_config" {
      for_each = each.value.external_ip ? [1] : []
      content {}
    }
  }

  service_account {
    email  = each.value.service_account_email
    scopes = each.value.service_account_scopes
  }

  metadata = merge(
    each.value.startup_script != "" ? { startup-script = each.value.startup_script } : {},
    each.value.shutdown_script != "" ? { shutdown-script = each.value.shutdown_script } : {}
  )

  allow_stopping_for_update = true
}
