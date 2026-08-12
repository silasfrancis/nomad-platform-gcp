# Falco Webhook service: A small Go application that receives Falco's JSON alerts 
# (Falco itself runs as a host systemd service on every client node via Ansible).
# Receives alerts from Falco, forwards to Loki (label: source=falco) and, for
# severity >= WARNING, calls nomad-sentinel over internal HTTP.

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

      # Routed through traefik-internal's dedicated "internal"
      # entrypoint. This is what gives Falco (running as a host systemd service on every client
      # node via Ansible) a stable URL to send its alerts to.
      tags = [
        "traefik.enable=true",
        "traefik.http.routers.falco-webhook.rule=Host(`falco-webhook-#{Environment}.platform.lefrancis.org`)",
        "traefik.http.routers.falco-webhook.entrypoints=internal", 
        "traefik.http.routers.falco-webhook.tls.certresolver=letsencrypt",
      ]

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
        # Explicit localhost avoids depending on Nomad's generated
        # NOMAD_UPSTREAM_ADDR_* variable naming for hyphenated services.
        AI_AGENT_ADDR = "localhost:8090"
      }

      resources {
        cpu    = #{Cpu}
        memory = #{Memory}
      }
    }
  }
}
