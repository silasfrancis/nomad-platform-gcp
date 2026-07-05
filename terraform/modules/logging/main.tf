# Custom Log Bucket for VPC Flow Logs
#
# A Cloud Logging bucket (Cloud Logging's own storage — NOT a GCS bucket)
# with shorter retention than the project's _Default bucket (30 days).
# Flow logs are the only thing routed here; everything else keeps landing
# in _Default untouched, since sinks only move what matches their filter.

resource "google_logging_project_bucket_config" "flow_logs" {
  project        = var.project_id
  location       = var.region
  bucket_id      = var.bucket_id
  retention_days = var.retention_days
  description    = "VPC flow logs"
  cmek_settings {
        kms_key_name = var.storage-cmek
    }
}

# Sink Routing Flow Logs Into The Custom Bucket

resource "google_logging_project_sink" "flow_logs" {
  project     = var.project_id
  name         = "vpc-flow-logs-sink"
  destination  = "logging.googleapis.com/${google_logging_project_bucket_config.flow_logs.id}"
  filter       = var.flow_logs_filter

  # false: uses the shared Cloud Logging service identity rather than
  # provisioning a dedicated one.
  unique_writer_identity = false
}

# Exclude Flow Logs From _Default
#
# Without this, flow logs land in BOTH _Default (30-day retention) and the
# custom bucket above (7-day) — same data, paid for twice.

resource "google_logging_project_sink" "default" {
  project     = var.project_id
  name         = "_Default"
  destination  = "logging.googleapis.com/projects/${var.project_id}/locations/global/buckets/_Default"

  exclusions {
    name        = "exclude-vpc-flow-logs"
    description = "Flow logs are routed to the network-flow-logs bucket."
    filter      = var.flow_logs_filter
  }
}
