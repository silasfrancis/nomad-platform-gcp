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
      mode = "bridge"

      port "http" {
        to = 8080
      }
    }

    service {
      name = "metrics-api"
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
        "traefik.http.routers.metrics-api.rule=Host(`metrics-api-#{Environment}.platform.lefrancis.org`)",
        "traefik.http.routers.metrics-api.entrypoints=internal",
        "traefik.http.routers.metrics-api.tls.certresolver=letsencrypt",
      ]

      connect {
        sidecar_service {
          proxy {
            upstreams {
              destination_name = "postgres"
              local_bind_port  = 5432
            }
          }
          tags = ["traefik.enable=false"]
        }

        # One upstream, receiving-only otherwise — 100/128 floor.
        sidecar_task {
          resources {
            cpu    = 100
            memory = 128
          }
        }
      }
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
      }

      template {
        data = <<EOF
{{ with secret "database/creds/metrics-api-#{Environment}" }}
DATABASE_URL=postgresql://{{ .Data.username }}:{{ .Data.password }}@{{ env "NOMAD_UPSTREAM_ADDR_postgres" }}/metrics?sslmode=disable
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
