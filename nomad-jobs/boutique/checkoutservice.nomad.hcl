# nomad-jobs/boutique/checkoutservice.nomad.hcl
#
# Canary deployment, on-demand only — orchestrates the actual purchase
# transaction across 6 downstream services.

job "checkoutservice" {
  datacenters = ["#{Datacenter}"]
  namespace   = "boutique"
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
    count = 1

    constraint {
      attribute = "${meta.node_pool_type}"
      operator  = "="
      value     = "on-demand"
    }

    network {
      port "grpc" {
        to = 5050
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
        PRODUCT_CATALOG_SERVICE_ADDR = "productcatalogservice.service.consul:3550"
        SHIPPING_SERVICE_ADDR        = "shippingservice.service.consul:50051"
        PAYMENT_SERVICE_ADDR         = "paymentservice.service.consul:50051"
        EMAIL_SERVICE_ADDR           = "emailservice.service.consul:8080"
        CURRENCY_SERVICE_ADDR        = "currencyservice.service.consul:7000"
        CART_SERVICE_ADDR            = "cartservice.service.consul:7070"
      }

      resources {
        cpu    = #{Cpu}
        memory = #{Memory}
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
      }
    }
  }
}
