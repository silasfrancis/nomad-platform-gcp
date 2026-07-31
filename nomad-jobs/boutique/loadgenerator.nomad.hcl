# nomad-jobs/boutique/loadgenerator.nomad.hcl
#
# Headless Locust, generating continuous traffic against frontend.
# Purely outbound — no port to expose, nothing else discovers it via
# Consul, so no network/service stanza is needed (unlike every other
# job in this namespace). Hard spot-only: test traffic, zero
# production impact if preempted.

job "loadgenerator" {
  datacenters = ["#{Datacenter}"]
  namespace   = "boutique"
  type        = "service"

  update {
    max_parallel     = 1
    min_healthy_time = "10s"
    healthy_deadline = "3m"
    auto_revert      = true
  }

  group "loadgenerator" {
    count = 1

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
        SPAWN_RATE    = "1"
        LOCUST_HEADLESS = "true"
      }

      resources {
        cpu    = #{Cpu}
        memory = #{Memory}
      }
    }
  }
}
