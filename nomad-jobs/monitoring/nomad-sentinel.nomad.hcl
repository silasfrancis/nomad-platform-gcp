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
# HISTORY_DATABASE_URL: the architecture doc describes this as
# "shared credentials" with metrics-api, but giving nomad-sentinel a
# copy of metrics-api's own dynamic role seems like the wrong kind of
# sharing (two unrelated services holding the same credential rather
# than each having their own, scoped role). Using a separate
# nomad-sentinel-specific dynamic role against the same "monitoring"
# database instead — same net effect (one Postgres instance, agent_anomalies
# table), better isolation. Flagging the deviation from the doc's literal
# wording rather than silently matching it.

job "nomad-sentinel#{DeploymentSlot}" {
  datacenters = ["#{Datacenter}"]
  namespace   = "monitoring"
  type        = "service"

  update {
    max_parallel     = 1
    min_healthy_time = "10s"
    healthy_deadline = "3m"
    auto_revert      = true
  }

  group "nomad-sentinel" {
    count = 1

    # Monitoring must survive Spot preemption.
    constraint {
      attribute = "${meta.node_pool_type}"
      operator  = "="
      value     = "on-demand"
    }

    network {
      port "http" {
        to = 8090
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
HISTORY_DATABASE_URL=postgresql://{{ .Data.username }}:{{ .Data.password }}@postgres-#{Environment}.service.consul:5432/monitoring?sslmode=disable
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
      }
    }
  }
}
