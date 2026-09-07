job "adservice" {
  datacenters = ["#{Datacenter}"]
  namespace   = "#{DeploymentNamespace}"
  type        = "service"

  update {
    max_parallel     = 1
    min_healthy_time = "10s"
    healthy_deadline = "3m"
    auto_revert      = true
  }

  group "adservice" {
    count = #{ReplicaCount}

    constraint {
      attribute = "${meta.node_pool_type}"
      operator  = "="
      value     = "spot"
    }

    network {
      mode = "bridge"

      port "grpc" {
        to = 9555
      }
    }

    service {
      name = "adservice"
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

        sidecar_task {
          resources {
            cpu    = 100
            memory = 128
          }
        }
      }
    }

    task "adservice" {
      driver = "docker"

      config {
        image = "#{ArtifactRegistry}/adservice:#{ImageTag}"
        ports = ["grpc"]
      }

      env {
        PORT = "9555"
      }

      resources {
        cpu    = #{Cpu}
        memory = #{Memory}
      }
    }
  }
}
