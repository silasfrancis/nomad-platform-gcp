# nomad-jobs/boutique/currencyservice.nomad.hcl
#
# Rolling deployment (Nomad default — no canary/blue-green needed for
# a stateless, non-customer-facing-directly service). Soft affinity
# toward Spot: stateless gRPC, Nomad reschedules cleanly on
# preemption, so there's no hard requirement to stay on-demand.

job "currencyservice" {
  datacenters = ["#{Datacenter}"]
  namespace   = "boutique"
  type        = "service"

  update {
    max_parallel     = 1
    min_healthy_time = "10s"
    healthy_deadline = "3m"
    auto_revert      = true
  }

  group "currencyservice" {
    count = 1

    affinity {
      attribute = "${meta.node_pool_type}"
      operator  = "="
      value     = "spot"
      weight    = 50
    }

    network {
      port "grpc" {
        to = 7000
      }
    }

    task "currencyservice" {
      driver = "docker"

      config {
        image = "#{ArtifactRegistry}/currencyservice:#{ImageTag}"
        ports = ["grpc"]
      }

      env {
        PORT = "7000"
      }

      resources {
        cpu    = #{Cpu}
        memory = #{Memory}
      }

      service {
        name = "currencyservice"
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
