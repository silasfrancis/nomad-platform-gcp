# nomad-jobs/monitoring/node-exporter.nomad.hcl
#
# System job — one per client node, same reasoning as alloy.nomad.hcl.
# Needs host PID/network namespace access to report real host-level
# metrics rather than the container's own isolated view.

job "node-exporter" {
  datacenters = ["#{Datacenter}"]
  namespace   = "#{DeploymentNamespace}"
  type        = "system"

  update {
    max_parallel     = 1
    min_healthy_time = "10s"
    healthy_deadline = "3m"
  }

  group "node-exporter" {
    network {
      port "http" {
        to = 9100
      }
    }

    task "node-exporter" {
      driver = "docker"

      config {
        image        = "prom/node-exporter:v1.8.2"
        ports        = ["http"]
        network_mode = "host"
        pid_mode     = "host"
        args = [
          "--path.rootfs=/host",
          "--collector.filesystem.mount-points-exclude=^/(dev|proc|sys|var/lib/docker)($$|/)",
        ]
        volumes = [
          "/:/host:ro,rslave",
        ]
      }

      resources {
        cpu    = #{Cpu}
        memory = #{Memory}
      }

      service {
        name = "node-exporter"
        port = "http"

        check {
          type     = "http"
          path     = "/metrics"
          interval = "15s"
          timeout  = "3s"
        }
      }
    }
  }
}
