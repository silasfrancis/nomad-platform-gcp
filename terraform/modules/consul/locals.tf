# Intentions Call Graph — destination => list of allowed source
# services. Built directly from:
#   - docker-compose.services.yaml: frontend's *_ADDR env vars,
#     checkoutservice's *_ADDR env vars, cartservice's REDIS_ADDR
#   - This session's decisions: metrics-api + ai-agent (nomad-sentinel)
#     both connect to the same PostgreSQL Nomad job, different
#     databases (metrics / monitoring)
#
# Deny-by-default (ACL default_policy = "deny") means anything NOT
# listed here cannot call the destination service at all.
#
# "frontend" intentionally absent as a destination — its only real
# callers are Traefik (catalog provider, not Connect) and loadgenerator
# (plain published port), neither of which is a mesh member, so it has
# no legitimate mesh-internal caller and needs no intention entry.
#
# NOTE: no mesh_services list here anymore — the 14-service x 2-env
# static sidecar identity token block (acl-sidecar-tokens.tf) was
# dropped entirely this session. Nomad 1.7+'s native Consul Workload
# Identity mints each sidecar's scoped ACL token automatically at
# allocation time via `connect { sidecar_service {} }` in the job spec
# (confirmed against Nomad's own docs), using the nomad-client
# policy's acl:write grant below — no static per-service token needs
# to be pre-created or distributed here at all.
locals {
  intentions = {
    productcatalogservice  = ["frontend", "checkoutservice", "recommendationservice"]
    currencyservice        = ["frontend", "checkoutservice"]
    cartservice             = ["frontend", "checkoutservice"]
    recommendationservice   = ["frontend"]
    shippingservice          = ["frontend", "checkoutservice"]
    checkoutservice          = ["frontend"]
    adservice                = ["frontend"]
    paymentservice           = ["checkoutservice"]
    emailservice              = ["checkoutservice"]
    "redis-cart"              = ["cartservice"]
    postgresql                = ["metrics-api", "ai-agent"]
  }
}
