variable "project_id" {
  type = string
}

variable "region" {
  type = string
}

variable "artifact_registry_repo" {
  type = string
}

variable "storage_cmek"{
  type = string
}

variable "repository_iam" {
  description = <<-EOT
    Map of IAM role bindings on the Artifact Registry repository. 
    Supports standard predefined roles, custom roles, and optional CEL conditions.
    Example:
      repository_iam = {
        "roles/artifactregistry.writer" = {
          members = ["serviceAccount:management-vm-sa@project.iam.gserviceaccount.com"]
        }
      }
  EOT
  type = map(object({
    members   = list(string)
    condition = optional(object({
      title       = string
      description = optional(string)
      expression  = string
    }))
  }))
  default = {}
}

variable "immutable_tags" {
  description = "Whether image tags are immutable — once pushed, a tag cannot be overwritten."
  type    = bool
  default = true
}

variable "image_keep_count" {
  description = "Number of most recent image versions to retain per image name."
  type    = number
  default = 20
}

variable "additional_labels" {
  description = "Additional labels to merge onto resources that support them."
  type        = map(string)
  default     = {}
}