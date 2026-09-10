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
      attribute = "${node.class}"
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
        static = 9090
        to = 9090
      }
    }

    service {
      name = "prometheus"
      port = "http"

      tags = [
        "traefik.enable=true",
        "traefik.http.routers.prometheus.rule=Host(`prometheus-#{Environment}.platform.lefrancis.org`)",
        "traefik.http.routers.prometheus.entrypoints=internal",
        "traefik.http.routers.prometheus.tls.certresolver=letsencrypt",
      ]

      check {
        type     = "http"
        path     = "/-/healthy"
        interval = "10s"
        timeout  = "2s"
      }
    }

    vault {
      role = "prometheus"
    }

    # Runs once, as root, before the main task starts. Fixes ownership
    # on the CSI volume so the main "prometheus" task can run as nobody
    # without needing chown privileges itself.
    task "volume-permissions" {
      driver = "docker"

      lifecycle {
        hook    = "prestart"
        sidecar = false
      }

      config {
        image   = "busybox:1.36"
        command = "sh"
        args    = [
          "-c",
          "chown nobody:nobody /prometheus && find /prometheus -mindepth 1 -maxdepth 1 -not -name lost+found -exec chown -R nobody:nobody {} +"
        ]
      }

      volume_mount {
        volume      = "prometheus-data"
        destination = "/prometheus"
      }

      resources {
        cpu    = 50
        memory = 64
      }
    }

    task "prometheus" {
      driver = "docker"

      config {
        image = "#{ArtifactRegistry}/prometheus:#{ImageTag}"
        ports = ["http"]

        mount {
          type   = "bind"
          source = "secrets/consul-ca.pem"
          target = "/etc/prometheus/consul-ca.pem"
        }
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

      template {
        data = <<EOF
  {{ with secret "kv/data/pki/#{Environment}/consul-ca" }}
  {{ .Data.data.ca_cert }}
  {{ end }}
  EOF
        destination = "secrets/consul-ca.pem"
      }

      env {
        ENV                    = "#{Environment}"
        TRAEFIK_PUBLIC_IP      = "#{TraefikPublicIp}"
        TRAEFIK_PUBLIC_PORT    = "#{TraefikPublicPort}"
        TRAEFIK_INTERNAL_IP    = "#{TraefikInternalIp}"
        TRAEFIK_INTERNAL_PORT  = "#{TraefikInternalPort}"
        CONSUL_SERVER_CA_FILE  = "/etc/prometheus/consul-ca.pem"
        CONSUL_HTTP_ADDR       = "${attr.unique.network.ip-address}:8501"
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
}