# nomad-jobs/boutique/productcatalogservice.nomad.hcl
#
# Canary deployment, on-demand only. No secrets — just serves a
# static product list.
#
# Connect mesh retrofit: service {} moved from task-level to
# group-level — Consul Connect requires this (the sidecar attaches to
# the group's bridge network, not an individual task). Receiving-only:
# nothing this service calls itself, so no upstreams block, just the
# empty sidecar_service {} needed to accept mesh traffic from
# frontend/checkoutservice/recommendationservice.

job "productcatalogservice" {
  datacenters = ["#{Datacenter}"]
  namespace   = "#{DeploymentNamespace}"
  type        = "service"

  update {
    max_parallel      = 1
    canary            = 1
    min_healthy_time  = "30s"
    healthy_deadline  = "5m"
    progress_deadline = "10m"
    auto_revert       = true
    auto_promote      = false
  }

  group "productcatalogservice" {
    count = #{ReplicaCount}

    constraint {
      attribute = "${meta.node_pool_type}"
      operator  = "="
      value     = "on-demand"
    }

    network {
      mode = "bridge"

      port "grpc" {
        to = 3550
      }
    }

    service {
      name = "productcatalogservice"
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

    task "productcatalogservice" {
      driver = "docker"

      config {
        image = "#{ArtifactRegistry}/productcatalogservice:#{ImageTag}"
        ports = ["grpc"]
      }

      env {
        PORT = "3550"
      }

      resources {
        cpu    = #{Cpu}
        memory = #{Memory}
      }
    }
  }
}
