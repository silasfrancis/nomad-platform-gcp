# nomad-jobs/monitoring/prometheus.nomad.hcl
#
# One instance per environment (this same job spec promoted dev ->
# prod, scraping only its own cluster — dev and prod are never
# federated). Scrape config itself lives in configs/prometheus/ (not
# in this repo directory), pulled in via the artifact stanza below
# from the platform-artifacts GCS bucket rather than baked into this
# file — so updating scrape targets doesn't require a new job version.

job "prometheus" {
  datacenters = ["#{Datacenter}"]
  namespace   = "monitoring"
  type        = "service"

  update {
    max_parallel     = 1
    min_healthy_time = "10s"
    healthy_deadline = "3m"
    auto_revert      = true
  }

  group "prometheus" {
    count = 1

    constraint {
      attribute = "${meta.node_pool_type}"
      operator  = "="
      value     = "on-demand"
    }

    volume "prometheus-data" {
      type      = "host"
      source    = "prometheus-data-#{Environment}"
      read_only = false
    }

    network {
      port "http" {
        to = 9090
      }
    }

    task "prometheus" {
      driver = "docker"

      config {
        image   = "prom/prometheus:v2.55.1"
        ports   = ["http"]
        args    = ["--config.file=/local/prometheus.yml", "--storage.tsdb.path=/prometheus"]
        volumes = ["prometheus-data:/prometheus"]
      }

      artifact {
        source      = "gcs::https://www.googleapis.com/storage/v1/platform-artifacts/configs/prometheus/#{Environment}.yml"
        destination = "local/prometheus.yml"
      }

      resources {
        cpu    = #{Cpu}
        memory = #{Memory}
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
    }
  }
}
