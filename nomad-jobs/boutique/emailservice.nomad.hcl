# nomad-jobs/boutique/emailservice.nomad.hcl
#
# Rolling deployment, soft affinity toward Spot. Logs a mock
# confirmation only — reads just PORT + DISABLE_PROFILER, no external
# secrets or real email provider integration.

job "emailservice" {
  datacenters = ["#{Datacenter}"]
  namespace   = "#{DeploymentNamespace}"
  type        = "service"

  update {
    max_parallel     = 1
    min_healthy_time = "10s"
    healthy_deadline = "3m"
    auto_revert      = true
  }

  group "emailservice" {
    count = #{ReplicaCount}

    affinity {
      attribute = "${meta.node_pool_type}"
      operator  = "="
      value     = "spot"
      weight    = 50
    }

    network {
      port "grpc" {
        to = 8080
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

      service {
        name = "emailservice"
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
