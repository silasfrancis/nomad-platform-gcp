job "nomad-sentinel" {
  datacenters = ["#{Datacenter}"]
  namespace   = "#{DeploymentNamespace}"
  type        = "service"

  # Roll allocations one at a time so each replacement can become healthy
  # before the next allocation is restarted during Vault credential rotation.
  update {
    canary            = 0
    max_parallel      = 1
    min_healthy_time  = "30s"
    healthy_deadline  = "5m"
    progress_deadline = "10m"
    auto_revert       = true
  }

  group "nomad-sentinel" {
    count = #{ReplicaCount}

    # Monitoring must survive Spot preemption.
    constraint {
      attribute = "${meta.node_pool_type}"
      operator  = "="
      value     = "on-demand"
    }

    network {
      mode = "bridge"

      port "http" {
        to = 8090
      }
    }

    service {
      name = "nomad-sentinel"
      port = "http"

      check {
        type     = "http"
        path     = "/health"
        interval = "10s"
        timeout  = "2s"
      }

      tags = [
        "metrics",
        "traefik.enable=true",
        "traefik.http.routers.nomad-sentinel.rule=Host(`nomad-sentinel-#{Environment}.platform.lefrancis.org`)",
        "traefik.http.routers.nomad-sentinel.entrypoints=internal",
        "traefik.http.routers.nomad-sentinel.tls.certresolver=letsencrypt",
      ]
    }

      connect {
        sidecar_service {
          proxy {
            upstreams {
              destination_name = "postgres"
              local_bind_port  = 5432
            }
          }
          tags = []
        }

        sidecar_task {
          resources {
            cpu    = 100
            memory = 128
          }
        }
      }
    }

    vault {
      role = "nomad-sentinel"
    }

    task "nomad-sentinel" {
      driver = "docker"

      config {
        image = "#{ArtifactRegistry}/nomad-sentinel:#{ImageTag}"
        ports = ["http"]
      }

      # Nomad's own signed workload identity, exposed as NOMAD_TOKEN —
      # the standard env var name the nomad CLI/API client already
      # looks for by convention, so nomad-sentinel's own Nomad-API
      # calls need no special-casing on the app side.
      identity {
        env = true
      }

      env {
        PORT             = "8090"
        REMEDIATION_MODE = "#{RemediationMode}"
      }

    template {
      data = <<EOF
{{ with secret "kv/data/#{Environment}/nomad-sentinel/config" }}
GEMINI_API_KEY={{ .Data.data.gemini_api_key }}
SLACK_WEBHOOK_URL={{ .Data.data.slack_webhook_url }}
{{ end }}

{{ with secret "database/creds/monitoring-#{Environment}" }}
HISTORY_DATABASE_URL=postgresql://{{ .Data.username }}:{{ .Data.password }}@{{ env "NOMAD_UPSTREAM_ADDR_postgres" }}/monitoring?sslmode=disable
{{ end }}
EOF

      destination = "secrets/nomad-sentinel-config.env"
      env         = true
      # Vault dynamically rotates credentials, so restart the allocation when secrets
      # change to ensure the replacement allocation picks up the new credentials.
      change_mode = "restart"
    }

    resources {
      cpu    = #{Cpu}
      memory = #{Memory}
    }
  }
}

