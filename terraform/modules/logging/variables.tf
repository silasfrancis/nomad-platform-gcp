variable "project_id" {
  type = string
}

variable "storage-cmek" {
  type = string
}

variable "region" {
  description = "Location for the custom log bucket. Must match whatever region the _Default sink/bucket already uses if you later want log views to line up; 'global' is GCP's usual default for _Default."
  type        = string
}

variable "bucket_id" {
  description = "ID of the custom Cloud Logging bucket (NOT a GCS bucket — this is Cloud Logging's own storage)."
  type        = string
  default     = "network-flow-logs"
}

variable "retention_days" {
  description = "How long flow logs are kept in the custom bucket. Default (30 days) is GCP's own default for _Default; lower this for cost."
  type        = number
  default     = 7
}

variable "flow_logs_filter" {
  description = "Filter matching VPC flow log entries — used both to route them into the custom bucket and to exclude them from _Default (avoids paying to store the same entries twice)."
  type        = string
  default     = "resource.type=\"gce_subnetwork\" AND log_id(\"compute.googleapis.com/vpc_flows\")"
}
