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

job "alloy" {
  datacenters = ["#{Datacenter}"]
  namespace   = "monitoring"
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
        image   = "grafana/alloy:v1.5.1"
        ports   = ["http"]
        args    = ["run", "/local/config.alloy"]
        volumes = [
          "/var/nomad/alloc:/var/nomad/alloc:ro",
        ]
      }

      artifact {
        source      = "gcs::https://www.googleapis.com/storage/v1/platform-artifacts/configs/alloy/#{Environment}.alloy"
        destination = "local/config.alloy"
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
