# nomad-jobs/boutique/currencyservice.nomad.hcl
#
# Rolling deployment (Nomad default). Soft affinity toward Spot.
# Connect mesh retrofit: service {} at group level (Consul Connect
# requirement), receiving-only — called by frontend/checkoutservice.

job "currencyservice" {
  datacenters = ["#{Datacenter}"]
  namespace   = "#{DeploymentNamespace}"
  type        = "service"

  update {
    max_parallel     = 1
    min_healthy_time = "10s"
    healthy_deadline = "3m"
    auto_revert      = true
  }

  group "currencyservice" {
    count = #{ReplicaCount}

    affinity {
      attribute = "${meta.node_pool_type}"
      operator  = "="
      value     = "spot"
      weight    = 50
    }

    network {
      mode = "bridge"

      port "grpc" {
        to = 7000
      }
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
    }
  }
}
