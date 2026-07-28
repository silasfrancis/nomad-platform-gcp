# Intentions Call Graph — destination => list of allowed source
# services. Built directly from the application's own service-to-
# service wiring (each service's configured upstream addresses),
# rather than assumed.
#
# "frontend" is intentionally absent as a destination — its only real
# callers are the edge proxy and a load-testing tool, neither of which
# is a mesh member (see modules/nomad job specs), so it has no
# legitimate mesh-internal caller and needs no intention entry.
locals {
  intentions = {
    productcatalogservice  = ["frontend", "checkoutservice", "recommendationservice"]
    currencyservice        = ["frontend", "checkoutservice"]
    cartservice            = ["frontend", "checkoutservice"]
    recommendationservice  = ["frontend"]
    shippingservice        = ["frontend", "checkoutservice"]
    checkoutservice        = ["frontend"]
    adservice              = ["frontend"]
    paymentservice         = ["checkoutservice"]
    emailservice           = ["checkoutservice"]
    "redis-cart"           = ["cartservice"]
    postgresql             = ["metrics-api", "nomad-sentinel"]
  }
}
