# Prometheus config is baked into its own image (monitoring/prometheus/
# source directory).
# Deliberately not Connect-meshed: Prometheus scrapes every target's
# real port directly, it isn't
# making the kind of app-to-app call Connect upstreams are for.


job "prometheus" {
  datacenters = ["#{Datacenter}"]
  namespace   = "#{DeploymentNamespace}"
  type        = "service"

  update {
    max_parallel     = 1
    min_healthy_time = "10s"
    healthy_deadline = "3m"
    auto_revert      = true
  }

  group "prometheus" {
    count = #{ReplicaCount}

    constraint {
      attribute = "${meta.node_pool_type}"
      operator  = "="
      value     = "on-demand"
    }

    volume "prometheus-data" {
      type            = "csi"
      source          = "prometheus-data-#{Environment}"
      read_only       = false
      attachment_mode = "file-system"
      access_mode     = "single-node-writer"
    }

    network {
      port "http" {
        to = 9090
      }
    }

    service {
      name = "prometheus"
      port = "http"

      check {
        type     = "http"
        path     = "/-/healthy"
        interval = "10s"
        timeout  = "2s"
      }
    }

      tags = [
        "traefik.enable=true",
        "traefik.http.routers.prometheus.rule=Host(`prometheus-#{Environment}.platform.lefrancis.org`)",
        "traefik.http.routers.prometheus.entrypoints=internal",
        "traefik.http.routers.prometheus.tls.certresolver=letsencrypt",
      ]
    }

    vault {
      role = "nomad-sentinel"
    }
    
    task "prometheus" {
      driver = "docker"

      config {
        image = "#{ArtifactRegistry}/prometheus:#{ImageTag}"
        ports = ["http"]
      }
      
      env {
        TRAEFIK_PUBLIC_IP = "#{TraefikPublicIp}"
        TRAEFIK_PUBLIC_PORT = "#{TraefikPublicPort}"
        
        TRAEFIK_INTERNAL_IP = "#{TraefikInternalIp}"
        TRAEFIK_INTERNAL_PORT = "#{TraefikInternalPort}"
      }

      template {
        data = <<EOF
{{ with secret "kv/data/#{Environment}/prometheus/config" }}
CONSUL_PROMETHEUS_TOKEN={{ .Data.data.consul_prometheus_token }}
{{ end }}
EOF
        destination = "secrets/prometheus-config.env"
        env         = true
      }

      volume_mount {
        volume      = "prometheus-data"
        destination = "/prometheus"
      }

      resources {
        cpu    = #{Cpu}
        memory = #{Memory}
      }
    }
}
