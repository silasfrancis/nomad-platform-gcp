# bootstrap/variables.tf

variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "region" {
  description = "Primary GCP region for all resources"
  type        = string
}

variable "project_number" {
  description = <<-EOT
    GCP project number (not project ID).
    Required to construct service agent email addresses for KMS IAM bindings.
    Find it: gcloud projects describe <project_id> --format='value(projectNumber)'
  EOT
  type        = string
}

variable "environment" {
  type        = string
}
