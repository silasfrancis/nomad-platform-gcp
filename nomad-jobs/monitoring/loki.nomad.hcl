job "loki" {
  datacenters = ["#{Datacenter}"]
  namespace   = "#{DeploymentNamespace}"
  type        = "service"

  update {
    max_parallel     = 1
    min_healthy_time = "10s"
    healthy_deadline = "3m"
    auto_revert      = true
  }

  group "loki" {
    count = #{ReplicaCount}

    constraint {
      attribute = "${node.class}"
      operator  = "="
      value     = "on-demand"
    }

    network {
      mode = "bridge"

      port "http" {
        to = 3100
      }
    }

    service {
      name = "loki"
      port = "http"

      check {
        type     = "http"
        path     = "/ready"
        interval = "10s"
        timeout  = "2s"
      }

      # Grafana on mgmt-vm reaches Loki through Traefik's
      # dedicated internal entrypoint.
      tags = [
        "traefik.enable=true",
        "traefik.http.routers.loki.rule=Host(`loki-#{Environment}.platform.lefrancis.org`)",
        "traefik.http.routers.loki.entrypoints=internal",
        "traefik.http.routers.loki.tls.certresolver=letsencrypt",
      ]

      connect {
        sidecar_service {
          tags = ["traefik.enable=false"]
        }

        sidecar_task {
          resources {
            cpu    = 100
            memory = 128
          }
        }
      }
    }

    task "loki" {
      driver = "docker"

      config {
        image = "#{ArtifactRegistry}/loki:#{ImageTag}"
        ports = ["http"]

        args = [
          "-config.file=/etc/loki/loki.yaml",
          "-config.expand-env=true",
        ]
      }

      env {
        LOKI_GCS_BUCKET = "#{PlatformGcsBucket}"
        LOKI_GCS_PREFIX = "loki/#{Environment}"
      }

      resources {
        cpu    = #{Cpu}
        memory = #{Memory}
      }
    }
  }
}