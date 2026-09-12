job "frontend" {
  datacenters = ["#{Datacenter}"]
  namespace   = "#{DeploymentNamespace}"
  node_pool   = "on-demand"
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

  group "frontend" {
    count = #{ReplicaCount}

    constraint {
      attribute = "${node.class}"
      operator  = "="
      value     = "critical"
    }

    scaling {
      min     = 1
      max     = 5
      enabled = true

      policy {
        cooldown            = "2m"
        evaluation_interval = "30s"

        check "cpu_usage" {
          source = "prometheus"
          query  = "avg(nomad_client_allocs_cpu_total_percent{task_group=\"frontend\"})"

          strategy "target-value" {
            target = 70
          }
        }
      }
    }

    network {
      mode = "bridge"

      port "http" {
        to = 8080
      }
    }

    service {
      name = "frontend"
      port = "http"

      check {
        type     = "http"
        path     = "/_healthz"
        interval = "10s"
        timeout  = "2s"
      }

      tags = [
        "metrics",
        "traefik.enable=true",
        "traefik.http.routers.frontend.rule=Host(`#{PublicHostname}`)",
        "traefik.http.routers.frontend.tls.certresolver=letsencrypt",
      ]

      connect {
        sidecar_service {
          proxy {
            upstreams {
              destination_name = "productcatalogservice"
              local_bind_port  = 3550
            }
            upstreams {
              destination_name = "currencyservice"
              local_bind_port  = 7000
            }
            upstreams {
              destination_name = "cartservice"
              local_bind_port  = 7070
            }
            upstreams {
              destination_name = "recommendationservice"
              local_bind_port  = 8082 # remote port is 8080, same as frontend's own — see header comment
            }
            upstreams {
              destination_name = "shippingservice"
              local_bind_port  = 50051
            }
            upstreams {
              destination_name = "checkoutservice"
              local_bind_port  = 5050
            }
            upstreams {
              destination_name = "adservice"
              local_bind_port  = 9555
            }
          }
          tags = ["traefik.enable=false"]
        }

        # 7 upstreams — highest in this whole retrofit, sized up
        # accordingly from the single-upstream floor.
        sidecar_task {
          resources {
            cpu    = 150
            memory = 192
          }
        }
      }
    }

    task "frontend" {
      driver = "docker"

      config {
        image = "#{ArtifactRegistry}/frontend:#{ImageTag}"
        ports = ["http"]
      }

      env {
        PORT                          = "8080"
        ENV_PLATFORM                  = "gcp"
        PRODUCT_CATALOG_SERVICE_ADDR  = "${NOMAD_UPSTREAM_ADDR_productcatalogservice}"
        CURRENCY_SERVICE_ADDR         = "${NOMAD_UPSTREAM_ADDR_currencyservice}"
        CART_SERVICE_ADDR             = "${NOMAD_UPSTREAM_ADDR_cartservice}"
        RECOMMENDATION_SERVICE_ADDR   = "${NOMAD_UPSTREAM_ADDR_recommendationservice}"
        SHIPPING_SERVICE_ADDR         = "${NOMAD_UPSTREAM_ADDR_shippingservice}"
        CHECKOUT_SERVICE_ADDR         = "${NOMAD_UPSTREAM_ADDR_checkoutservice}"
        AD_SERVICE_ADDR               = "${NOMAD_UPSTREAM_ADDR_adservice}"
      }

      resources {
        cpu    = #{Cpu}
        memory = #{Memory}
      }
    }
  }
}
