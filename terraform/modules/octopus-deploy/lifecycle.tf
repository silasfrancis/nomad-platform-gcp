# Deployment Lifecycle
#
# Development promotes automatically on release creation. Production is
# an optional phase reached only through manual approval in the Octopus UI

resource "octopusdeploy_lifecycle" "main" {
  name        = "main"
  description = "Development promotes automatically; Production requires manual approval."

  release_retention_with_strategy {
    strategy         = "Count"
    quantity_to_keep = 10
    unit             = "Items"
  }

  tentacle_retention_with_strategy {
    strategy         = "Count"
    quantity_to_keep = 10
    unit             = "Items"
  }

  phase {
    name                         = "Development"
    automatic_deployment_targets = [octopusdeploy_environment.dev.id]
  }

  phase {
    name                        = "Production"
    optional_deployment_targets = [octopusdeploy_environment.prod.id]
  }
}
