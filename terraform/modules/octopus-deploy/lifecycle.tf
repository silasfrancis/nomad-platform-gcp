# Deployment Lifecycle
#
# Development promotes automatically on release creation. Production is
# an optional phase reached only through manual approval in the Octopus
# UI — no automatic_deployment_targets entry for it.
#
# NOTE: release_retention_with_strategy/tentacle_retention_with_strategy
# are the current, non-deprecated retention blocks (replacing the
# older release_retention_policy/tentacle_retention_policy blocks found
# in older examples). The lifecycle-level shape below (strategy,
# quantity_to_keep, unit) is confirmed against the provider's own
# retention_policy_with_strategy usage elsewhere; the same block
# repeated per-phase has not been independently re-verified — confirm
# against current docs before applying if phase-level retention needs
# to differ from the lifecycle-level default below.
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
