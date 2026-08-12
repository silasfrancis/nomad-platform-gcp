# Log Buckets
#
# Add a new entry to var.log_buckets to create another bucket — the sink
# routing logs into it and the exclusion keeping it out of _Default are
# both generated automatically per entry, nothing else needs to change here.
# All buckets use default_cmek_key unless an entry sets its own cmek_key.

locals {
  buckets = {
    for name, bucket in var.log_buckets : name => merge(bucket, {
      location = coalesce(bucket.location, var.region)
      cmek_key = coalesce(bucket.cmek_key, var.default_cmek_key)
    })
  }
}

resource "google_logging_project_bucket_config" "this" {
  for_each = local.buckets

  project        = var.project_id
  location       = each.value.location
  bucket_id      = each.key
  retention_days = each.value.retention_days
  description    = each.value.description

  cmek_settings {
    kms_key_name = each.value.cmek_key
  }

}


# Sink Routing Flow Logs Into The Custom Bucket

resource "google_logging_project_sink" "this" {
  for_each = local.buckets

  project     = var.project_id
  name         = "${each.key}-sink"
  destination  = "logging.googleapis.com/${google_logging_project_bucket_config.this[each.key].id}"
  filter       = each.value.filter

  unique_writer_identity = false
}

# _Default Sink — Excludes Everything Routed To A Custom Bucket
#
# Without these exclusions, every custom-bucket log would ALSO keep landing
# in _Default (30-day retention) — same data stored twice, billed twice.
# One exclusion block is generated per entry in var.log_buckets.

resource "google_logging_project_sink" "default" {
  project     = var.project_id
  name         = "_Default"
  destination  = "logging.googleapis.com/projects/${var.project_id}/locations/global/buckets/_Default"

  dynamic "exclusions" {
    for_each = local.buckets
    content {
      name        = "exclude-${exclusions.key}"
      description = "Routed to the ${exclusions.key} bucket instead (see ${exclusions.key}-sink)."
      filter      = exclusions.value.filter
    }
  }
}
