# nomad-jobs/boutique/frontend.nomad.hcl
#
# The only boutique service reached from outside the platform — routed
# by traefik-dev-public/traefik-prod-public's consulCatalog via the
# traefik.* tags below. Canary deployment: a new version runs
# alongside the stable one, gets smoke-tested, then is promoted
# explicitly (auto_promote = false — this is Octopus's `nomad
# deployment promote` step, not automatic).

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
      port "http" {
        to = 8080
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
        PRODUCT_CATALOG_SERVICE_ADDR  = "productcatalogservice.service.consul:3550"
        CURRENCY_SERVICE_ADDR         = "currencyservice.service.consul:7000"
        CART_SERVICE_ADDR             = "cartservice.service.consul:7070"
        RECOMMENDATION_SERVICE_ADDR   = "recommendationservice.service.consul:8080"
        SHIPPING_SERVICE_ADDR         = "shippingservice.service.consul:50051"
        CHECKOUT_SERVICE_ADDR         = "checkoutservice.service.consul:5050"
        AD_SERVICE_ADDR               = "adservice.service.consul:9555"
        # SHOPPING_ASSISTANT_SERVICE_ADDR intentionally omitted — see
        # architecture doc 13, requires GCP AlloyDB + Secret Manager,
        # neither used in this project.
      }

      resources {
        cpu    = #{Cpu}
        memory = #{Memory}
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
      }
    }
  }
}
