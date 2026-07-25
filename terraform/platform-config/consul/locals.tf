locals {
  # Mesh Members — Every Service Getting A Sidecar + Service-Identity
  # Token. Derived directly from docker-compose.services.yaml's actual
  # depends_on/env-address wiring, not guessed.
  #
  # loadgenerator and Traefik are deliberately EXCLUDED. Neither
  # presents a mesh mTLS identity — loadgenerator calls frontend's
  # plain published port exactly like a real end user would (it's test
  # traffic, per the architecture doc: "zero production impact"), and
  # Traefik uses Consul's catalog provider, not Connect, to reach
  # frontend. Both reach their target outside the mesh entirely, same
  # as any other external caller. This is also why "frontend" never
  # appears as a destination in the intentions map below — its only
  # real callers are these two non-mesh members, so it has no
  # legitimate mesh-internal caller and needs no intention entry at all.
  mesh_services = toset([
    "frontend", "cartservice", "checkoutservice", "productcatalogservice",
    "currencyservice", "paymentservice", "shippingservice", "emailservice",
    "recommendationservice", "adservice", "redis-cart", "postgresql",
    "metrics-api", "ai-agent",
  ])

  # Intentions Call Graph — destination => list of allowed source
  # services. Built directly from:
  #   - docker-compose.services.yaml: frontend's *_ADDR env vars,
  #     checkoutservice's *_ADDR env vars, cartservice's REDIS_ADDR
  #   - This session's decisions: metrics-api + ai-agent (nomad-sentinel)
  #     both connect to the same PostgreSQL Nomad job, different
  #     databases (metrics / monitoring)
  #
  # Deny-by-default (ACL default_policy = "deny") means anything NOT
  # listed here cannot call the destination service at all — this map
  # is deliberately exhaustive for the mesh members above, not a
  # starting subset.
  intentions = {
    productcatalogservice = ["frontend", "checkoutservice", "recommendationservice"]
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
    # frontend: intentionally absent — see comment above mesh_services
  }
}
