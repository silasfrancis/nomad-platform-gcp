# nomad-jobs/boutique/adservice.nomad.hcl
#
# Rolling deployment, hard spot-only — fully stateless, non-critical.

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
      port "grpc" {
        to = 9555
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

      service {
        name = "adservice"
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
