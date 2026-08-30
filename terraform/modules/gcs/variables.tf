variable "project_id" {
  type = string
}

variable "region" {
  type = string
}

variable "additional_labels" {
  type    = map(string)
  default = {}
}

variable "environment" {
  type    = string
  default = "shared"
}

variable "storage_cmek" {
  type    = string
  default = ""
}

variable "backup_retention_days" {
  type    = number
  default = 30
}

variable "buckets" {
  description = <<-EOT
    Map of GCS buckets configurations, properties, and IAM policies.
    Each bucket key acts as the resource name unless 'name_override' is specified.

    Example — defining buckets with distinct retention periods and custom IAM roles:
      buckets = {
        "my-project-us-central1-platform-artifacts" = {
          backup_retention_days = 90
          enable_tiering        = true
          labels = {
            environment = "shared"
            purpose     = "platform-backups"
          }
          iam = {
            "roles/storage.objectCreator" = {
              members = ["serviceAccount:management-vm-sa@project.iam.gserviceaccount.com"]
            }
            "roles/storage.objectViewer" = {
              members = ["serviceAccount:management-vm-sa@project.iam.gserviceaccount.com"]
            }
          }
        }
      }

    Custom roles or conditions can also be supplied per IAM binding map entry.
  EOT
  type = map(object({
    name_override             = optional(string)
    storage_class             = optional(string)
    kms_key_id                = optional(string)
    versioning_enabled        = optional(bool)
    soft_delete_retention     = optional(number)
    force_destroy             = optional(bool)
    deletion_policy           = optional(string)
    backup_retention_days     = optional(number)
    enable_tiering            = optional(bool)
    override_default_iam      = optional(bool)
    logging = optional(object({
      enabled    = bool
      log_bucket = string
      prefix     = string
    }))
    labels = optional(map(string))
    iam = optional(map(object({
      members   = list(string)
      condition = optional(object({
        title       = string
        description = optional(string)
        expression  = string
      }))
    })))
  }))
  default = {}
}