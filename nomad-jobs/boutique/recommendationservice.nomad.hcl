# nomad-jobs/boutique/recommendationservice.nomad.hcl
#
# Rolling deployment, hard spot-only. Connect mesh retrofit:
# group-level service {}, one upstream (productcatalogservice) — env
# var switches from Consul DNS to localhost:<local_bind_port>, since
# with Connect a service talks to its own sidecar, never directly to
# the remote one.

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

      connect {
        sidecar_service {
          proxy {
            upstreams {
              destination_name = "productcatalogservice"
              local_bind_port  = 3550
            }
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
        PRODUCT_CATALOG_SERVICE_ADDR = "localhost:3550"
      }

      resources {
        cpu    = #{Cpu}
        memory = #{Memory}
      }
    }
  }
}
