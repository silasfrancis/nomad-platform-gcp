# nomad-jobs/monitoring/nomad-sentinel.nomad.hcl
#
# Same blue-green caveat as metrics-api.nomad.hcl applies here too —
# no Traefik route exists for this service in the doc's routing table
# either.
#
# REMEDIATION_MODE has no default anywhere in this file, on purpose —
# per architecture doc 7.3, the agent crash-fails at startup if it's
# invalid or unset. #{RemediationMode} must be "execute" in dev's
# Octopus variable set and "propose" in prod's — never implicit.
#
# HISTORY_DATABASE_URL uses its own dedicated dynamic Vault role
# against the same "monitoring" database, rather than sharing
# metrics-api's role as the architecture doc's wording literally
# suggests — better isolation, flagged as an intentional deviation.
#
# Connect mesh retrofit: group-level service {}, one upstream
# (postgres-#{Environment}) for HISTORY_DATABASE_URL, now
# localhost:5432 instead of Consul DNS.

job "nomad-sentinel#{DeploymentSlot}" {
  datacenters = ["#{Datacenter}"]
  namespace   = "#{DeploymentNamespace}"
  type        = "service"

  update {
    max_parallel     = 1
    min_healthy_time = "10s"
    healthy_deadline = "3m"
    auto_revert      = true
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
      name = "nomad-sentinel#{DeploymentSlot}"
      port = "http"

      check {
        type     = "http"
        path     = "/health"
        interval = "10s"
        timeout  = "2s"
      }

      tags = ["metrics"]

      connect {
        sidecar_service {
          proxy {
            upstreams {
              destination_name = "postgres-#{Environment}"
              local_bind_port  = 5432
            }
          }
        }
      }
    }

    vault {
      role        = "nomad-sentinel-#{Environment}"
      change_mode = "noop"
    }

    task "nomad-sentinel" {
      driver = "docker"

      config {
        image = "#{ArtifactRegistry}/nomad-sentinel:#{ImageTag}"
        ports = ["http"]
      }

      template {
        data = <<EOF
{{ with secret "kv/data/#{Environment}/ai-agent/config" }}
GEMINI_API_KEY={{ .Data.data.gemini_api_key }}
SLACK_WEBHOOK_URL={{ .Data.data.slack_webhook_url }}
NOMAD_TOKEN={{ .Data.data.nomad_token }}
{{ end }}
{{ with secret "database/creds/#{Environment}-nomad-sentinel" }}
HISTORY_DATABASE_URL=postgresql://{{ .Data.username }}:{{ .Data.password }}@localhost:5432/monitoring?sslmode=disable
{{ end }}
PORT=8090
REMEDIATION_MODE=#{RemediationMode}
EOF
        destination = "secrets/nomad-sentinel.env"
        env         = true
        change_mode = "noop"
      }

      resources {
        cpu    = #{Cpu}
        memory = #{Memory}
      }
    }
  }
}
