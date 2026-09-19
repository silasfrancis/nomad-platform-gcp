job "metrics-api" {
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

  group "metrics-api" {
    count = #{ReplicaCount}

    constraint {
      attribute = "${node.class}"
      operator  = "="
      value     = "critical"
    }

    network {
      port "http" {
        to = 8080
      }
    }

    service {
      name = "metrics-api"
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
        "traefik.http.routers.metrics-api.rule=Host(`metrics-api-#{Environment}.platform.lefrancis.org`)",
        "traefik.http.routers.metrics-api.entrypoints=internal",
        "traefik.http.routers.metrics-api.tls.certresolver=letsencrypt",
      ]
    }

    vault {
      role = "metrics-api"
    }

    task "metrics-api" {
      driver = "docker"

      config {
        image = "#{ArtifactRegistry}/metrics-api:#{ImageTag}"
        ports = ["http"]
      }

      env {
        PORT = "8080"
        POSTGRES_ADDR = "postgres.service.consul:5432"
      }

      template {
        data = <<EOF
{{ with secret "database/creds/metrics-api-#{Environment}" }}
{{ $cred := . }}
{{ range service "postgres" }}
DATABASE_URL=postgresql://{{ $cred.Data.username }}:{{ $cred.Data.password }}@{{ .Address }}:{{ .Port }}/metrics?sslmode=disable
{{ end }}
{{ end }}
EOF
        destination = "secrets/metrics-api-config.env"
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
