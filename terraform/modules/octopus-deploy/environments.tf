# NOTE: "description" is a confirmed field on this resource. An
# environment-level "tags" field was requested but its exact argument
# name isn't confirmed against the current provider schema — verify
# against the provider docs before relying on one; omitted here rather
# than guessed.
resource "octopusdeploy_environment" "dev" {
  name        = "Development"
  description = "Automatic deployment target for every release created from a merge to main."
}

resource "octopusdeploy_environment" "prod" {
  name        = "Production"
  description = "Customer-facing environment. Releases only reach this environment after manual approval."
}
