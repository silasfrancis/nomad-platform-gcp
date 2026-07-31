# nomad-jobs/boutique/productcatalogservice.nomad.hcl
#
# Canary deployment, on-demand only. No secrets — just serves a
# static product list.

job "productcatalogservice" {
  datacenters = ["#{Datacenter}"]
  namespace   = "boutique"
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
    count = 1

    constraint {
      attribute = "${meta.node_pool_type}"
      operator  = "="
      value     = "on-demand"
    }

    network {
      port "grpc" {
        to = 3550
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

      service {
        name = "productcatalogservice"
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
