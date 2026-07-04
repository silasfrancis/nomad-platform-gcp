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

variable "artifact_registry_writer_members" {
  description = <<-EOT
    IAM members granted roles/artifactregistry.writer on the platform repository.
    Typically: management-vm-sa (GitHub runner pushes images on CI).
    Format: ["serviceAccount:management-vm-sa@<project>.iam.gserviceaccount.com"]
  EOT
  type    = list(string)
  default = []
}

variable "artifact_registry_reader_members" {
  description = <<-EOT
    IAM members granted roles/artifactregistry.reader on the platform repository.
    Typically: nomad-client-sa (client nodes pull images to run Nomad Docker jobs).
    Format: ["serviceAccount:nomad-client-sa@<project>.iam.gserviceaccount.com"]
  EOT
  type    = list(string)
  default = []
}

variable "additional_registry_iam" {
  description = <<-EOT
    Additional IAM role bindings on the Artifact Registry repository.
    Use for roles beyond writer/reader without touching locals.
    Format matches artifact_registry_iam structure:
      additional_registry_iam = {
        "roles/artifactregistry.repoAdmin" = {
          members = ["user:admin@lefrancis.org"]
        }
      }
  EOT
  type = map(object({
    members = list(string)
  }))
  default = {}
}

variable "immutable_tags" {
  description = <<-EOT
    Whether image tags are immutable — once pushed, a tag cannot be overwritten.
    Safe to enable when all images are SHA-tagged (CI never pushes the same SHA twice).
    Set to false if you need to update floating tags like "latest".
  EOT
  type    = bool
  default = true
}

variable "image_keep_count" {
  description = <<-EOT
    Number of most recent image versions to retain per image name.
    Older versions are automatically deleted by the cleanup policy.
    With 13 services: 20 versions × 13 = up to 260 images retained.
  EOT
  type    = number
  default = 20
}

variable "additional_labels" {
  description = "Additional labels to merge onto resources that support them."
  type        = map(string)
  default     = {}
}