# Namespaces — default Already Exists Built-In, No Resource Needed For It
# Provider aliasing means each namespace needs one resource per env —
# a for_each across a combined {dev, prod} map can't dynamically select
# a provider, so these are written out per alias rather than looped.

resource "nomad_namespace" "monitoring_dev" {
  provider = nomad.dev
  name     = "monitoring"
}

resource "nomad_namespace" "monitoring_prod" {
  provider = nomad.prod
  name     = "monitoring"
}

resource "nomad_namespace" "security_dev" {
  provider = nomad.dev
  name     = "security"
}

resource "nomad_namespace" "security_prod" {
  provider = nomad.prod
  name     = "security"
}

resource "nomad_namespace" "core_dev" {
  provider = nomad.dev
  name     = "core"
}

resource "nomad_namespace" "core_prod" {
  provider = nomad.prod
  name     = "core"
}
