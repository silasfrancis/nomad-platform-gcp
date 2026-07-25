# Namespaces — default Already Exists Built-In, No Resource Needed.
resource "nomad_namespace" "monitoring" {
  name = "monitoring"
}

resource "nomad_namespace" "security" {
  name = "security"
}

resource "nomad_namespace" "core" {
  name = "core"
}
