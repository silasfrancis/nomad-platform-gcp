# Service Intentions — Deny-By-Default, Explicit Allow Per Pair
#
# One config_entry per destination service, generated from
# locals.intentions. L4-only (Sources[].Action) — no L7 path/method
# matching is used yet, though the same resource type supports it
# without any restructuring if finer-grained rules are ever needed.
#
# No explicit "deny all others" entry exists here: ACL
# default_policy = "deny" already covers every pair not listed below,
# with no additional resource required.
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
