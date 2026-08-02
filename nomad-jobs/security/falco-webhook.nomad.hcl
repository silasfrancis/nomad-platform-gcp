# nomad-jobs/security/falco-webhook.nomad.hcl
#
# Small Go service — receives Falco's JSON alerts (Falco itself runs
# as a host systemd service on every client node via Ansible, not a
# Nomad job at all). Forwards to Loki (label: source=falco) and, for
# severity >= WARNING, calls nomad-sentinel over internal HTTP.
#
# AI_AGENT_ADDR's upstream points at nomad-sentinel without a
# blue/green suffix — same open question flagged in
# nomad-sentinel.nomad.hcl about what the blue/green switch actually
# resolves for callers.
#
# Connect mesh retrofit: group-level service {}, two upstreams —
# loki's remote port (3100) and nomad-sentinel's (8090) don't collide
# with each other, so no offset needed on either.

job "falco-webhook" {
  datacenters = ["#{Datacenter}"]
  namespace   = "#{DeploymentNamespace}"
  type        = "service"

  update {
    max_parallel     = 1
    min_healthy_time = "10s"
    healthy_deadline = "3m"
    auto_revert      = true
  }

  group "falco-webhook" {
    count = #{ReplicaCount}

    network {
      mode = "bridge"

      port "http" {
        to = 8080
      }
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

      connect {
        sidecar_service {
          proxy {
            upstreams {
              destination_name = "loki"
              local_bind_port  = 3100
            }
            upstreams {
              destination_name = "nomad-sentinel"
              local_bind_port  = 8090
            }
          }
        }
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
        LOKI_ADDR     = "localhost:3100"
        AI_AGENT_ADDR = "localhost:8090"
      }

      resources {
        cpu    = #{Cpu}
        memory = #{Memory}
      }
    }
  }
}
