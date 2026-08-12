output "log_buckets" {
  description = "Map of all created logging project bucket configurations."
  value = {
    for name, bucket in google_logging_project_bucket_config.this : name => {
      id             = bucket.id
      name           = bucket.bucket_id
      location       = bucket.location
      retention_days = bucket.retention_days
    }
  }
}

output "log_sinks" {
  description = "Map of all created logging project sinks."
  value = {
    for name, sink in google_logging_project_sink.this : name => {
      id          = sink.id
      name        = sink.name
      destination = sink.destination
    }
  }
}