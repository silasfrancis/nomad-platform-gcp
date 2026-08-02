# nomad-jobs/boutique/checkoutservice.nomad.hcl
#
# Canary deployment, on-demand only — orchestrates the actual purchase
# transaction across 6 downstream services. Connect mesh retrofit:
# group-level service {}, 6 upstreams — every *_ADDR env var switches
# from Consul DNS to localhost:<local_bind_port>, one port per
# upstream, matching each downstream service's own port so nothing
# else needs to change on their end.

job "checkoutservice" {
  datacenters = ["#{Datacenter}"]
  namespace   = "#{DeploymentNamespace}"
  type        = "service"

  update {
    max_parallel      = 1
    canary            = 1
    min_healthy_time  = "30s"
    healthy_deadline  = "5m"
    progress_deadline = "10m"
    auto_revert       = true
    auto_promote      = false
  }

  group "checkoutservice" {
    count = #{ReplicaCount}

    constraint {
      attribute = "${meta.node_pool_type}"
      operator  = "="
      value     = "on-demand"
    }

    network {
      mode = "bridge"

      port "grpc" {
        to = 5050
      }
    }

    service {
      name = "checkoutservice"
      port = "grpc"

      check {
        type     = "grpc"
        port     = "grpc"
        interval = "10s"
        timeout  = "2s"
      }

      connect {
        sidecar_service {
          proxy {
            upstreams {
              destination_name = "productcatalogservice"
              local_bind_port  = 3550
            }
            upstreams {
              destination_name = "shippingservice"
              local_bind_port  = 50051
            }
            upstreams {
              destination_name = "paymentservice"
              local_bind_port  = 50052 # can't reuse 50051 — shippingservice already claims it on this same sidecar
            }
            upstreams {
              destination_name = "emailservice"
              local_bind_port  = 8080
            }
            upstreams {
              destination_name = "currencyservice"
              local_bind_port  = 7000
            }
            upstreams {
              destination_name = "cartservice"
              local_bind_port  = 7070
            }
          }
        }
      }
    }

    task "checkoutservice" {
      driver = "docker"

      config {
        image = "#{ArtifactRegistry}/checkoutservice:#{ImageTag}"
        ports = ["grpc"]
      }

      env {
        PORT                         = "5050"
        PRODUCT_CATALOG_SERVICE_ADDR = "localhost:3550"
        SHIPPING_SERVICE_ADDR        = "localhost:50051"
        PAYMENT_SERVICE_ADDR         = "localhost:50052"
        EMAIL_SERVICE_ADDR           = "localhost:8080"
        CURRENCY_SERVICE_ADDR        = "localhost:7000"
        CART_SERVICE_ADDR            = "localhost:7070"
      }

      resources {
        cpu    = #{Cpu}
        memory = #{Memory}
      }
    }
  }
}
