resource "octopusdeploy_environment" "dev" {
  name = "Development"
}

resource "octopusdeploy_environment" "prod" {
  name = "Production"
}

# NOTE: verify this resource's exact phase-block schema against the
# current provider docs before applying — lifecycle/phase argument names
# have shifted across octopusdeploy provider versions and this is
# written from general knowledge of the shape, not a freshly-checked
# schema.
resource "octopusdeploy_lifecycle" "main" {
  name = "main"

  phase {
    name                          = "Development"
    automatic_deployment_targets  = [octopusdeploy_environment.dev.id]
  }

  phase {
    name                         = "Production"
    optional_deployment_targets = [octopusdeploy_environment.prod.id]
    # Manual approval gate on prod (architecture doc section 6.4) —
    # confirm whether this belongs here as a lifecycle phase setting or
    # as a project-level deployment-process "manual intervention" step;
    # the provider may model this differently than a lifecycle-phase flag.
  }
}
