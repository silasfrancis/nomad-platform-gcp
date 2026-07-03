variable "project_id" {
  type = string
}

variable "region" {
  type = string
}

variable "repo_name" {
  type = string
}

variable "gcs_storage_key_id"{
  type = string
}

variable "additional_labels" {
  type        = map(string)
  description = "Additional labels to apply to the repository."
  default     = {}
}

variable "additional_artifact_registry_iam" {
  type        = map(object({ members = list(string) }))
  description = "Additional IAM roles to add to the repository."
  default     = {}
}

variable "artifact_registry_creator_members" {
  type        = list(string)
  description = "IAM members granted roles/artifactregistry.writer on the repository."
  default     = []
}

variable "artifact_registry_viewer_members" {
  type        = list(string)
  description = "IAM members granted roles/artifactregistry.reader on the repository."
  default     = []
}
