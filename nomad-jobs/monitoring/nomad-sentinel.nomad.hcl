job "nomad-sentinel" {
  datacenters = ["#{Datacenter}"]
  namespace   = "#{DeploymentNamespace}"
  node_pool   = "on-demand"
  type        = "service"

  # Roll allocations one at a time so each replacement can become healthy
  # before the next allocation is restarted during Vault credential rotation.
  update {
    max_parallel      = 1
    min_healthy_time  = "30s"
    healthy_deadline  = "5m"
    progress_deadline = "10m"
    auto_revert       = true
  }

  group "nomad-sentinel" {
    count = #{ReplicaCount}

    constraint {
      attribute = "${node.class}"
      operator  = "="
      value     = "critical"
    }

    network {
      port "http" {
        to = 8090
      }
    }

    service {
      name = "nomad-sentinel"
      port = "http"

      check {
        type     = "http"
        port     = "http"
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

    vault {
      role = "nomad-sentinel"
    }

    task "nomad-sentinel" {
        driver = "docker"

        config {
          image = "#{ArtifactRegistry}/nomad-sentinel:#{ImageTag}"
          ports = ["http"]
        }

        identity {
          env = true
        }

      template {
        data = <<EOF
{{ with secret "kv/data/pki/#{Environment}/nomad-ca" }}
{{ .Data.data.ca_cert }}
{{ end }}
EOF
        destination = "secrets/nomad-ca.pem"
      }

        env {
          HTTP_PORT             = "8090"
          REMEDIATION_MODE = "#{RemediationMode}"
          GEMINI_MODEL = "gemini-3.5-flash-lite"
          ANOMALY_ALERT_COOLDOWN_SECONDS = 300
          NOMAD_CACERT = "/secrets/nomad-ca.pem"
          NOMAD_TLS_SERVER_NAME = "server.#{Datacenter}.nomad"
        }

      template {
        data = <<EOF
{{ with service "http.nomad" }}
{{ with index . 0 }}
NOMAD_ADDR=https://{{ .Address }}:{{ .Port }}
{{ end }}
{{ end }}
EOF
        destination = "local/nomad-addr.env"
        env         = true
      }

      template {
        data = <<EOF
{{ with secret "kv/data/#{Environment}/nomad-sentinel/config" }}
GEMINI_API_KEY={{ .Data.data.gemini_api_key }}
SLACK_WEBHOOK_URL={{ .Data.data.slack_webhook_url }}
{{ end }}

{{ with secret "database/creds/monitoring-#{Environment}" }}
{{ $cred := . }}
{{ range service "postgres" }}
HISTORY_DATABASE_URL=postgresql://{{ $cred.Data.username }}:{{ $cred.Data.password }}@{{ .Address }}:{{ .Port }}/monitoring?sslmode=disable
{{ end }}
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
}