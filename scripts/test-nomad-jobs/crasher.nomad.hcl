job "crasher" {
  datacenters = ["dc1"]
  type        = "service"

  group "app" {
    count = 1

    restart {
      attempts = 3
      interval = "30s"
      delay    = "2s"
      mode     = "fail"
    }

    reschedule {
      attempts      = 2
      unlimited     = false
      delay         = "5s"
      delay_function = "constant"
      interval      = "15s"
      max_delay     = "5s"
    }

    task "app" {
      driver = "docker"

      config {
        image   = "alpine"
        command = "sh"
        args    = ["-c", "exit 1"]
      }

      resources {
        cpu    = 100
        memory = 64
      }
    }
  }
}