# nomad-jobs/boutique/paymentservice.nomad.hcl
#
# Rolling deployment but hard on-demand — direct customer transaction
# path even though not one of the 4 canaried services. App mocks
# payment in-process; reads only PORT + DISABLE_PROFILER.
# Connect mesh retrofit: group-level service {}, receiving-only —
# called by checkoutservice.

job "paymentservice" {
  datacenters = ["#{Datacenter}"]
  namespace   = "#{DeploymentNamespace}"
  type        = "service"

  update {
    max_parallel     = 1
    min_healthy_time = "10s"
    healthy_deadline = "3m"
    auto_revert      = true
  }

  group "paymentservice" {
    count = #{ReplicaCount}

    constraint {
      attribute = "${meta.node_pool_type}"
      operator  = "="
      value     = "on-demand"
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
