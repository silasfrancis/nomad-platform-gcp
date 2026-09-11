# Worker MIGs (Nomad & Consul Clients)
#
# One instance template + one regional (multi-zone) MIG + one autoscaler
# per entry in var.migs. Everything is generated from that one map via
# for_each, adding a fifth pool later means adding one map entry, not
# three new resource blocks.

resource "google_compute_instance_template" "this" {
  for_each = var.migs

  project      = var.project_id
  name_prefix  = "${each.key}-"
  machine_type = each.value.machine_type

  tags   = each.value.tags
  labels = each.value.labels

  disk {
    source_image = each.value.boot_disk_image
    disk_size_gb = each.value.boot_disk_size_gb
    disk_type    = "pd-balanced"
    boot         = true
    auto_delete  = true
    disk_encryption_key {
      kms_key_self_link = var.disk_cmek_key
    }
  }

  network_interface {
    subnetwork = each.value.subnetwork
    # No access_config block — client nodes are private-only, reached via
    # IAP (SSH) and NAT (outbound), never a direct public IP.
  }

  service_account {
    email  = each.value.service_account_email
    scopes = ["cloud-platform"]
  }

  scheduling {
    preemptible         = each.value.spot
    automatic_restart   = !each.value.spot
    provisioning_model  = each.value.spot ? "SPOT" : "STANDARD"
    instance_termination_action = each.value.spot ? "STOP" : null
  }

  metadata = merge({
    env            = each.value.environment
    datacenter     = each.value.environment == "dev" ? "dc-dev" : "dc-prod"
    node_pool = each.value.spot ? "spot" : "on-demand"
    node_class = each.value.spot ? "preemptible" : "critical"
  },
    each.value.startup_script != "" ? { startup-script = each.value.startup_script } : {},
    each.value.spot && each.value.shutdown_script != "" ? { shutdown-script = each.value.shutdown_script } : {},
  )

  lifecycle {
    create_before_destroy = true
  }
}

# Basic TCP health check on Nomad's client API port. An MIG without auto-healing
# only replaces instances GCP itself terminates (Spot preemption); it
# won't catch a client whose Nomad agent has hung but is still running.
resource "google_compute_health_check" "this" {
  for_each = var.migs

  project             = var.project_id
  name                 = "${each.key}-health-check"
  check_interval_sec   = 30
  timeout_sec          = 10
  healthy_threshold    = 2
  unhealthy_threshold  = 3

  tcp_health_check {
    port = 4646
  }

  # log_config {
  #   enable = true
  # }
}

resource "google_compute_region_instance_group_manager" "this" {
  for_each = var.migs

  project             = var.project_id
  name                 = each.key
  region               = var.region
  base_instance_name   = each.key
  distribution_policy_zones = var.zones
  distribution_policy_target_shape = "EVEN"
  target_size          = each.value.min_replicas

  version {
    instance_template = google_compute_instance_template.this[each.key].id
  }

  auto_healing_policies {
    health_check      = google_compute_health_check.this[each.key].id
    initial_delay_sec = 300
  }

  named_port {
    name = "nomad-api"
    port = 4646
  }

  lifecycle{
    ignore_changes = [ target_size ]
  }
}

# REMOVED (2026-09-10): This and Nomad Autoscaler's gce-mig target driver
# (nomad-jobs/plugins/nomad-autoscaler.hcl) both resize this MIG based on
# unrelated signals (CPU util here vs. Nomad blocked-evals there) — they
# fight over target_size. HashiCorp's own gce-mig troubleshooting docs list
# "MIG scales down despite min=1" as a symptom of exactly this, caused by
# "external automation... modifying the MIG." Nomad Autoscaler is the sole
# intended owner of target_size here (see ignore_changes on the manager
# resource above, same reasoning). Re-add only for a pool with no matching
# Nomad Autoscaler policy.
#
# resource "google_compute_region_autoscaler" "this" {
#   for_each = var.migs

#   project = var.project_id
#   name    = "${each.key}-autoscaler"
#   region  = var.region
#   target  = google_compute_region_instance_group_manager.this[each.key].id

#   autoscaling_policy {
#     min_replicas         = each.value.min_replicas
#     max_replicas         = each.value.max_replicas
#     cooldown_period      = 90
#     stabilization_period = each.value.spot ? null : 300

#     cpu_utilization {
#       target = each.value.cpu_target
#     }

#     dynamic "scale_in_control" {
#       for_each = each.value.scale_in_control != null ? [each.value.scale_in_control] : []
#       content {
#         max_scaled_in_replicas {
#           fixed = scale_in_control.value.max_scaled_in_replicas_fixed
#         }
#         time_window_sec = scale_in_control.value.time_window_sec
#       }
#     }
#   }
# }
