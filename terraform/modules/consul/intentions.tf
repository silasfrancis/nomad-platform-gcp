# Service Intentions — Deny-By-Default, Explicit Allow Per Pair
#
# One config_entry per destination service, generated from
# locals.intentions, for this module's single environment.
#
# L4-only (Sources[].Action) — no L7 Permissions/HTTP path matching
# used yet. The resource type supports full L7 matching without
# restructuring anything here if finer-grained rules are ever needed
# (e.g. metrics-api's /db-check vs /metrics reachable by different
# callers).
#
# No nomad-sentinel -> nomad-server intention (Flag 6, resolved): that
# traffic is a plain Nomad API call, never Connect-mesh traffic, and
# nomad-server isn't a mesh member. No explicit "deny all others" —
# ACL default_policy = "deny" already covers every unlisted pair.

resource "consul_config_entry" "intention" {
  for_each = local.intentions

  kind = "service-intentions"
  name = each.key

  config_json = jsonencode({
    Sources = [
      for source in each.value : {
        Name   = source
        Action = "allow"
      }
    ]
  })
}
