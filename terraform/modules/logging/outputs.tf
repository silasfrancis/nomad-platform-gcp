output "bucket_id" {
  value = google_logging_project_bucket_config.flow_logs.bucket_id
}

output "bucket_name" {
  value = google_logging_project_bucket_config.flow_logs.name
}
