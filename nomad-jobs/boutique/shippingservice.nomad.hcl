# nomad-jobs/boutique/shippingservice.nomad.hcl
#
# Rolling deployment, soft affinity toward Spot — stateless gRPC,
# Nomad reschedules cleanly on preemption.

job "shippingservice" {
  datacenters = ["#{Datacenter}"]
  namespace   = "boutique"
  type        = "service"

  update {
    max_parallel     = 1
    min_healthy_time = "10s"
    healthy_deadline = "3m"
    auto_revert      = true
  }

  group "shippingservice" {
    count = 1

    affinity {
      attribute = "${meta.node_pool_type}"
      operator  = "="
      value     = "spot"
      weight    = 50
    }

    network {
      port "grpc" {
        to = 50051
      }
    }

    task "shippingservice" {
      driver = "docker"

      config {
        image = "#{ArtifactRegistry}/shippingservice:#{ImageTag}"
        ports = ["grpc"]
      }

      env {
        PORT = "50051"
      }

      resources {
        cpu    = #{Cpu}
        memory = #{Memory}
      }

      service {
        name = "shippingservice"
        port = "grpc"

        check {
          type     = "grpc"
          port     = "grpc"
          interval = "10s"
          timeout  = "2s"
        }
      }
    }
  }
}
