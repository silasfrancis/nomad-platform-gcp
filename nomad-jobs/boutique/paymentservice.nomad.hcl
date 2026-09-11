job "paymentservice" {
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

  group "paymentservice" {
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
        to = 50051
      }
    }

    service {
      name = "paymentservice"
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

    task "paymentservice" {
      driver = "docker"

      config {
        image = "#{ArtifactRegistry}/paymentservice:#{ImageTag}"
        ports = ["grpc"]
      }

      env {
        PORT             = "50051"
        DISABLE_PROFILER = "1"
      }

      resources {
        cpu    = #{Cpu}
        memory = #{Memory}
      }
    }
  }
}
