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
      type            = "csi"
      source          = "loki-data-#{Environment}"
      read_only       = false
      attachment_mode = "file-system"
      access_mode     = "single-node-writer"
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

      # Grafana on mgmt-vm reaches it via traefik-internal's dedicated "internal"
      # entrypoint, since Grafana isn't in the mesh at all.
      tags = [
        "traefik.enable=true",
        "traefik.http.routers.loki.rule=Host(`loki-#{Environment}.platform.lefrancis.org`)",
        "traefik.http.routers.loki.entrypoints=internal",
        "traefik.http.routers.loki.tls.certresolver=letsencrypt",
      ]

      connect {
        sidecar_service {}

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
      }

      volume_mount {
        volume      = "loki-data"
        destination = "/loki"
      }

      resources {
        cpu    = #{Cpu}
        memory = #{Memory}
      }
    }
  }
}
