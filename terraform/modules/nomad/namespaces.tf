# Platform Namespaces
#
# Grouped by operational concern rather than by team or service — each
# namespace is a blast-radius boundary for who can stop, restart, or
# read logs for what's inside it, independent of any data-level access
# controls Vault/Consul already provide.

resource "nomad_namespace" "this" {
  for_each = local.namespaces

  name        = each.key
  description = each.value.description
}