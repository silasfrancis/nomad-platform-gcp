# nomad-jobs/security/falco-webhook.nomad.hcl
#
# Small Go service — receives Falco's JSON alerts (Falco itself runs
# as a host systemd service on every client node via Ansible, not a
# Nomad job at all; see architecture doc 9.1). Forwards to Loki
# (label: source=falco) and, for severity >= WARNING, calls
# nomad-sentinel over internal HTTP.
#
# AI_AGENT_ADDR points at nomad-sentinel without a blue/green suffix —
# same open question flagged in nomad-sentinel.nomad.hcl about what
# the blue/green switch actually resolves for callers. Worth revisiting
# together once that's sorted out; not blocking this job existing.

job "falco-webhook" {
  datacenters = ["#{Datacenter}"]
  namespace   = "security"
  type        = "service"

  update {
    max_parallel     = 1
    min_healthy_time = "10s"
    healthy_deadline = "3m"
    auto_revert      = true
  }

  group "falco-webhook" {
    count = 1

    network {
      port "http" {
        to = 8080
      }
    }

    task "falco-webhook" {
      driver = "docker"

      config {
        image = "#{ArtifactRegistry}/falco-webhook:#{ImageTag}"
        ports = ["http"]
      }

      env {
        PORT          = "8080"
        LOKI_ADDR     = "loki.service.consul:3100"
        AI_AGENT_ADDR = "nomad-sentinel.service.consul:8090"
      }

      resources {
        cpu    = #{Cpu}
        memory = #{Memory}
      }

      service {
        name = "falco-webhook"
        port = "http"

        check {
          type     = "http"
          path     = "/health"
          interval = "10s"
          timeout  = "2s"
        }
      }
    }
  }
}
