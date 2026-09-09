job "productcatalogservice" {
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

  group "productcatalogservice" {
    count = #{ReplicaCount}

    constraint {
      attribute = "${meta.node_pool_type}"
      operator  = "="
      value     = "spot"
    }

    // affinity {
    //   attribute = "${meta.node_pool_type}"
    //   operator  = "="
    //   value     = "spot"
    //   weight    = 50
    // }

    network {
      mode = "bridge"

      port "grpc" {
        to = 3550
      }
    }

    service {
      name = "productcatalogservice"
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
        sidecar_service {}

        # Receiving-only sidecar (no upstreams of its own) — 100/128
        # is a workable floor. Hardcoded per your ask, not an Octopus var.
        sidecar_task {
          resources {
            cpu    = 100
            memory = 128
          }
        }
      }
    }

    task "productcatalogservice" {
      driver = "docker"

      config {
        image = "#{ArtifactRegistry}/productcatalogservice:#{ImageTag}"
        ports = ["grpc"]
      }

      env {
        PORT = "3550"
      }

      resources {
        cpu    = #{Cpu}
        memory = #{Memory}
      }
    }
  }
}
