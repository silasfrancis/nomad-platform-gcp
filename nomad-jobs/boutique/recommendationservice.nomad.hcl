job "recommendationservice" {
  datacenters = ["#{Datacenter}"]
  namespace   = "#{DeploymentNamespace}"
  node_pool   = "spot"
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
      attribute = "${node.class}"
      operator  = "="
      value     = "preemptible"
    }

    network {
      mode = "bridge"

      port "grpc" {
        to = 8080
      }
    }

    service {
      name = "recommendationservice"
      port = 8080

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
