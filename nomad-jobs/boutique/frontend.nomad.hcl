# nomad-jobs/boutique/frontend.nomad.hcl
#
# The only boutique service reached from outside the platform — Traefik
# calls it directly via Consul Catalog (plain reverse proxy, not
# through Connect), so its own inbound side is unaffected by this
# retrofit. Its 7 outbound calls to other boutique services now go
# through Connect upstreams instead of Consul DNS.
#
# One real collision, not just a mechanical port list: recommendationservice's
# remote port is 8080 — the exact same port frontend itself listens on
# within this allocation's own network namespace. local_bind_port 8082
# below avoids that; every other upstream's remote port is unique
# across this list, so no other offset was needed.
#
# Canary deployment: a new version runs alongside the stable one, gets
# smoke-tested, then is promoted explicitly (auto_promote = false —
# this is Octopus's `nomad deployment promote` step, not automatic).

job "frontend" {
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

  group "frontend" {
    count = #{ReplicaCount}

    # Direct customer transaction path — never Spot.
    constraint {
      attribute = "${meta.node_pool_type}"
      operator  = "="
      value     = "on-demand"
    }

    # Task scaling (HPA equivalent) — per architecture doc 2.5.
    # Scale in/out based on the nomad_apm Prometheus plugin, not raw
    # host CPU, so this reacts to actual request load.
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
        PRODUCT_CATALOG_SERVICE_ADDR  = "localhost:3550"
        CURRENCY_SERVICE_ADDR         = "localhost:7000"
        CART_SERVICE_ADDR             = "localhost:7070"
        RECOMMENDATION_SERVICE_ADDR   = "localhost:8082"
        SHIPPING_SERVICE_ADDR         = "localhost:50051"
        CHECKOUT_SERVICE_ADDR         = "localhost:5050"
        AD_SERVICE_ADDR               = "localhost:9555"
        # SHOPPING_ASSISTANT_SERVICE_ADDR intentionally omitted — see
        # architecture doc 13, requires GCP AlloyDB + Secret Manager,
        # neither used in this project.
      }

      resources {
        cpu    = #{Cpu}
        memory = #{Memory}
      }
    }
  }
}
