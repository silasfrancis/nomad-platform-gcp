# nomad-jobs/monitoring/loki.nomad.hcl
#
# One instance per environment — receives logs from that
# environment's Grafana Alloy instances. Config is baked into its own
# image (monitoring/loki/ source directory, own Dockerfile wrapping
# the upstream grafana/loki image + a loki.yml) — same pattern as
# every other job now, not templated at deploy time.
#
# Connect mesh retrofit (unrelated to the config-baking change above):
# group-level service {}, receiving-only — falco-webhook reaches this
# via its own upstream. Alloy also calls this, but see alloy.nomad.hcl
# for why that side isn't actually wired up yet.

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

      connect {
        sidecar_service {}
      }
    }

    task "loki" {
      driver = "docker"

      config {
        image   = "#{ArtifactRegistry}/loki:#{ImageTag}"
        ports   = ["http"]
        volumes = ["loki-data:/loki"]
      }

      resources {
        cpu    = #{Cpu}
        memory = #{Memory}
      }
    }
  }
}
