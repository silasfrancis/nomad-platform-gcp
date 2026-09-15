job "docker-cleanup" {
  datacenters = ["#{Datacenter}"]
  namespace   = "#{DeploymentNamespace}"
  node_pool   = "all"
  type        = "sysbatch"

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
