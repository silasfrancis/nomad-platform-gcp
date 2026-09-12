job "checkoutservice" {
  datacenters = ["#{Datacenter}"]
  namespace   = "#{DeploymentNamespace}"
  node_pool   = "spot"
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

    // affinity {
    //   attribute = "${node.class}"
    //   operator  = "="
    //   value     = "preemptible"
    //   weight    = 50
    // }

    constraint {
      attribute = "${node.class}"
      operator  = "="
      value     = "preemptible"
    }

    network {
      mode = "bridge"

      port "grpc" {
        to = 5050
      }
    }

    service {
      name = "checkoutservice"
      port = "5050"

      check {
        type     = "grpc"
        port     = "grpc"
        interval = "10s"
        timeout  = "2s"
      }

      tags = [
        "metrics"
      ]


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

        # 6 upstreams — modest bump over the single-upstream floor for
        # extra proxy concurrency headroom.
        sidecar_task {
          resources {
            cpu    = 150
            memory = 192
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
        PRODUCT_CATALOG_SERVICE_ADDR = "${NOMAD_UPSTREAM_ADDR_productcatalogservice}"
        SHIPPING_SERVICE_ADDR        = "${NOMAD_UPSTREAM_ADDR_shippingservice}"
        PAYMENT_SERVICE_ADDR         = "${NOMAD_UPSTREAM_ADDR_paymentservice}"
        EMAIL_SERVICE_ADDR           = "${NOMAD_UPSTREAM_ADDR_emailservice}"
        CURRENCY_SERVICE_ADDR        = "${NOMAD_UPSTREAM_ADDR_currencyservice}"
        CART_SERVICE_ADDR            = "${NOMAD_UPSTREAM_ADDR_cartservice}"
      }

      resources {
        cpu    = #{Cpu}
        memory = #{Memory}
      }
    }
  }
}
