job "loadgenerator" {
  datacenters = ["#{Datacenter}"]
  namespace   = "#{DeploymentNamespace}"
  type        = "batch"

  group "loadgenerator" {
    count = #{ReplicaCount}

    constraint {
      attribute = "${meta.node_pool_type}"
      operator  = "="
      value     = "spot"
    }

    task "loadgenerator" {
      driver = "docker"

      config {
        image = "#{ArtifactRegistry}/loadgenerator:#{ImageTag}"
      }

      env {
        FRONTEND_ADDR = "frontend.service.consul:8080"
        USERS         = "10"
        RATE          = "1"
      }

      resources {
        cpu    = #{Cpu}
        memory = #{Memory}
      }
    }
  }
}

