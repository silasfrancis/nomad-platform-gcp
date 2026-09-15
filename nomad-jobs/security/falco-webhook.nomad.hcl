job "falco-webhook" {
  datacenters = ["#{Datacenter}"]
  namespace   = "#{DeploymentNamespace}"
  node_pool   = "on-demand"
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
      port "http" {
        to = 8080
      }
    }

    service {
      name = "falco-webhook"
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
        "traefik.http.routers.falco-webhook.rule=Host(`falco-webhook-#{Environment}.platform.lefrancis.org`)",
        "traefik.http.routers.falco-webhook.entrypoints=internal", 
        "traefik.http.routers.falco-webhook.tls.certresolver=letsencrypt",
      ]
    }

    task "falco-webhook" {
      driver = "docker"

      config {
        image = "#{ArtifactRegistry}/falco-webhook:#{ImageTag}"
        ports = ["http"]
      }

      env {
        PORT          = "8080"
      }

      template {
        data = <<EOF
{{ range service "loki" }}
LOKI_ADDR={{ .Address }}:{{ .Port }}
{{ end }}
{{ range service "nomad-sentinel" }}
NOMAD_SENTINEL_ADDR={{ .Address }}:{{ .Port }}
{{ end }}
EOF
        destination = "secrets/runtime-addr.env"
        env         = true
        change_mode = "restart" 
      }

      resources {
        cpu    = #{Cpu}
        memory = #{Memory}
      }
    }
  }
}