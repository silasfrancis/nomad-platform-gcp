# nomad-jobs/boutique/recommendationservice.nomad.hcl
#
# Rolling deployment, hard spot-only. Connect mesh retrofit:
# group-level service {}, one upstream (productcatalogservice) —
# NOMAD_UPSTREAM_ADDR_productcatalogservice is Nomad's own generated
# env var for this upstream's sidecar address, used instead of
# hardcoding localhost:<port> so the value can never silently drift
# out of sync with whatever local_bind_port is actually set below.

job "recommendationservice" {
  datacenters = ["#{Datacenter}"]
  namespace   = "#{DeploymentNamespace}"
  type        = "service"

  update {
    max_parallel     = 1
    min_healthy_time = "10s"
    healthy_deadline = "3m"
    auto_revert      = true
  }

  group "recommendationservice" {
    count = #{ReplicaCount}

    constraint {
      attribute = "${meta.node_pool_type}"
      operator  = "="
      value     = "spot"
    }

    network {
      mode = "bridge"

      port "grpc" {
        to = 8080
      }
    }

    service {
      name = "recommendationservice"
      port = "grpc"

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
          }
        }

        # One upstream — 100/128 floor.
        sidecar_task {
          resources {
            cpu    = 100
            memory = 128
          }
        }
      }
    }

    task "recommendationservice" {
      driver = "docker"

      config {
        image = "#{ArtifactRegistry}/recommendationservice:#{ImageTag}"
        ports = ["grpc"]
      }

      env {
        PORT                         = "8080"
        PRODUCT_CATALOG_SERVICE_ADDR = "${NOMAD_UPSTREAM_ADDR_productcatalogservice}"
      }

      resources {
        cpu    = #{Cpu}
        memory = #{Memory}
      }
    }
  }
}
