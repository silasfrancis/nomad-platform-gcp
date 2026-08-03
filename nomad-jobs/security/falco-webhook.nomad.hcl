# nomad-jobs/security/falco-webhook.nomad.hcl
#
# Small Go service — receives Falco's JSON alerts (Falco itself runs
# as a host systemd service on every client node via Ansible, not a
# Nomad job at all). Forwards to Loki (label: source=falco) and, for
# severity >= WARNING, calls nomad-sentinel over internal HTTP.
#
# Connect mesh retrofit: group-level service {}, two upstreams —
# loki's remote port (3100) and nomad-sentinel's (8090) don't collide
# with each other, so no offset needed on either.
#
# LOKI_ADDR uses NOMAD_UPSTREAM_ADDR_loki. AI_AGENT_ADDR stays
# hardcoded at localhost:8090 rather than NOMAD_UPSTREAM_ADDR_nomad-sentinel
# — that name has a hyphen, and HashiCorp's own docs and a real,
# confirmed GitHub issue disagree on whether Nomad generates the env
# var with the literal hyphen or an underscore in its place. Rather
# than guess, this one stays as a plain hardcoded value matching
# nomad-sentinel's local_bind_port below — worth revisiting once
# that's actually verified against this Nomad version.

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

        # Two upstreams — 100/128 floor.
        sidecar_task {
          resources {
            cpu    = 100
            memory = 128
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
        LOKI_ADDR     = "${NOMAD_UPSTREAM_ADDR_loki}"
        AI_AGENT_ADDR = "localhost:8090"
      }

      resources {
        cpu    = #{Cpu}
        memory = #{Memory}
      }
    }
  }
}
