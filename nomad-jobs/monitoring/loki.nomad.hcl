# nomad-jobs/monitoring/loki.nomad.hcl
#
# One instance per environment — receives logs from that
# environment's Grafana Alloy instances only. Config pulled from
# configs/loki/ in GCS, same pattern as prometheus.nomad.hcl.

job "loki" {
  datacenters = ["#{Datacenter}"]
  namespace   = "monitoring"
  type        = "service"

  update {
    max_parallel     = 1
    min_healthy_time = "10s"
    healthy_deadline = "3m"
    auto_revert      = true
  }

  group "loki" {
    count = 1

    constraint {
      attribute = "${meta.node_pool_type}"
      operator  = "="
      value     = "on-demand"
    }

    volume "loki-data" {
      type      = "host"
      source    = "loki-data-#{Environment}"
      read_only = false
    }

    network {
      port "http" {
        to = 3100
      }
    }

    task "loki" {
      driver = "docker"

      config {
        image   = "grafana/loki:3.3.2"
        ports   = ["http"]
        args    = ["-config.file=/local/loki.yml"]
        volumes = ["loki-data:/loki"]
      }

      artifact {
        source      = "gcs::https://www.googleapis.com/storage/v1/platform-artifacts/configs/loki/#{Environment}.yml"
        destination = "local/loki.yml"
      }

      resources {
        cpu    = #{Cpu}
        memory = #{Memory}
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
      }
    }
  }
}
