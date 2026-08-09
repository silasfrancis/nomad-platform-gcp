# nomad-jobs/operations/docker-cleanup.nomad.hcl
#
# Runs a daily Docker system prune across every client node to prevent
# disk exhaustion from cached image layers, stopped containers, and build caches.
# Uses a system job type so that it automatically schedules an instance on
# every client node in the cluster without needing explicit counts or host constraints.
#
# Designed to run with a time filter ("until=24h") to ensure it never 
# accidentally deletes images that might be pulled concurrently during 
# an ongoing deployment.

job "docker-cleanup" {
  datacenters = ["#{Datacenter}"]
  namespace   = "#{DeploymentNamespace}"
  type        = "system"

  periodic {
    cron             = "0 4 * * *"
    prohibit_overlap = true
    time_zone        = "UTC"
  }

  group "docker-cleanup" {
    task "docker-cleanup" {
      driver = "docker"

      config {
        image   = "docker:cli"
        command = "/bin/sh"
        args    = ["-c", "docker system prune -a -f --filter 'until=24h'"]

        # Grants the container access to the host's Docker daemon socket
        # so it can execute prune commands against the underlying Docker engine.
        volumes = [
          "/var/run/docker.sock:/var/run/docker.sock"
        ]
      }

      resources {
        cpu    = #{Cpu}
        memory = #{Memory}
      }
    }
  }
}