# nomad-jobs/monitoring/alloy.nomad.hcl
#
# System job — Nomad places one allocation on every client node
# automatically (both on-demand and Spot; logs matter regardless of
# which pool a workload landed on), no count/canary/constraint needed
# the way service jobs use them. Tails /var/nomad/alloc/*/logs/* and
# ships to this environment's own Loki — per architecture doc 8.4,
# every task's logs are queryable via LogQL immediately after
# deployment, no sidecar injection or per-job log driver config
# needed.
#
# Config is baked into its own image (built via CI, same pattern as
# every application service) rather than templated at deploy time —
# Prometheus/Loki are the only two exceptions to that, per the actual
# deployment model. This needs a small custom Dockerfile wrapping the
# upstream grafana/alloy image + a config.alloy file, not just the
# stock image.

job "alloy" {
  datacenters = ["#{Datacenter}"]
  namespace   = "#{DeploymentNamespace}"
  type        = "system"

  update {
    max_parallel     = 1
    min_healthy_time = "10s"
    healthy_deadline = "3m"
  }

  group "alloy" {
    network {
      port "http" {
        to = 12345
      }
    }

    task "alloy" {
      driver = "docker"

      config {
        image   = "#{ArtifactRegistry}/alloy:#{ImageTag}"
        ports   = ["http"]
        args    = ["run", "/etc/alloy/config.alloy"]
        volumes = [
          "/var/nomad/alloc:/var/nomad/alloc:ro",
        ]
      }

      resources {
        cpu    = #{Cpu}
        memory = #{Memory}
      }

      service {
        name = "alloy"
        port = "http"

        check {
          type     = "http"
          path     = "/-/ready"
          interval = "10s"
          timeout  = "2s"
        }
      }
    }
  }
}
