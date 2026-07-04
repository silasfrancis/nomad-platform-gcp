output "artifact_registry_url" {
  value       = google_artifact_registry_repository.platform.registry_uri
  description = "Registry URI for the Artifact Registry repository"
}

output "artifact_registry_id" {
  description = "Full resource ID of the Artifact Registry repository. Used for IAM bindings in other layers."
  value       = google_artifact_registry_repository.platform.id
}