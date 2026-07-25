# Service Intentions — Deny-By-Default, Explicit Allow Per Pair
#
# One config_entry per destination service, generated from
# locals.intentions. Each entry's Sources list is L4-only (Action =
# "allow"/"deny" per source) — no L7 Permissions/HTTP path matching is
# used here, since nothing in this project currently needs
# method/path-level authorization within a service (e.g. gRPC route
# splitting by method). The full L7 schema (Permissions, HTTP,
# JWT-per-provider claims) is supported by this same resource type and
# can be added later per-service without restructuring anything, by
# swapping a source's `Action` for a `Permissions` block — see the
# reference doc excerpt kept in README.md for the exact shape if/when
# that's needed (e.g. if metrics-api's /db-check should be reachable by
# fewer callers than /metrics).
#
# Flag 6 (resolved this session): no nomad-sentinel -> nomad-server
# intention. That traffic is a plain Nomad API call (port 4646),
# never Connect-mesh traffic, and nomad-server is not a mesh member in
# the first place — an intention here would govern a connection type
# that doesn't exist. An explicit "deny all others" entry is likewise
# skipped: ACL default_policy = "deny" already covers every unlisted
# pair with no additional resource needed.

resource "consul_config_entry" "intention_dev" {
  provider = consul.dev
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

resource "consul_config_entry" "intention_prod" {
  provider = consul.prod
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
