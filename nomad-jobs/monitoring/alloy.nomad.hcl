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
