# nomad-jobs/boutique/recommendationservice.nomad.hcl
#
# Rolling deployment, hard spot-only — fully stateless, non-critical,
# batch-like recommendation lookups. Zero production impact if
# preempted mid-request; client retries.

job "recommendationservice" {
  datacenters = ["#{Datacenter}"]
  namespace   = "#{DeploymentNamespace}"
  type        = "service"

  update {
    max_parallel     = 1
    min_healthy_time = "10s"
    healthy_deadline = "3m"
    auto_revert      = true
  }

  group "recommendationservice" {
    count = #{ReplicaCount}

    constraint {
      attribute = "${meta.node_pool_type}"
      operator  = "="
      value     = "spot"
    }

    network {
      port "grpc" {
        to = 8080
      }
    }

    task "recommendationservice" {
      driver = "docker"

      config {
        image = "#{ArtifactRegistry}/recommendationservice:#{ImageTag}"
        ports = ["grpc"]
      }

      env {
        PORT                         = "8080"
        PRODUCT_CATALOG_SERVICE_ADDR = "productcatalogservice.service.consul:3550"
      }

      resources {
        cpu    = #{Cpu}
        memory = #{Memory}
      }

      service {
        name = "recommendationservice"
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
