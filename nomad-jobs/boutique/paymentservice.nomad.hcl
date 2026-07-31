# nomad-jobs/boutique/paymentservice.nomad.hcl
#
# Rolling deployment (not in the canary list) but still hard
# on-demand — it's on the direct customer transaction path even
# though it isn't one of the 4 services canaried, per the
# architecture doc's scheduling table. App mocks payment in-process;
# reads only PORT + DISABLE_PROFILER, no external secrets.

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
      port "grpc" {
        to = 50051
      }
    }

    task "paymentservice" {
      driver = "docker"

      config {
        image = "#{ArtifactRegistry}/paymentservice:#{ImageTag}"
        ports = ["grpc"]
      }

      env {
        PORT               = "50051"
        DISABLE_PROFILER   = "1"
      }

      resources {
        cpu    = #{Cpu}
        memory = #{Memory}
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
      }
    }
  }
}
