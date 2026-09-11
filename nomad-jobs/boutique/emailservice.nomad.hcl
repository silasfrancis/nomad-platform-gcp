job "emailservice" {
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

  group "emailservice" {
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
        to = 8080
      }
    }

    service {
      name = "emailservice"
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

    task "emailservice" {
      driver = "docker"

      config {
        image = "#{ArtifactRegistry}/emailservice:#{ImageTag}"
        ports = ["grpc"]
      }

      env {
        PORT             = "8080"
        DISABLE_PROFILER = "1"
      }

      resources {
        cpu    = #{Cpu}
        memory = #{Memory}
      }
    }
  }
}
