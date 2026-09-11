job "redis" {
  datacenters = ["#{Datacenter}"]
  namespace   = "#{DeploymentNamespace}"
  node_pool   = "on-demand"
  type        = "service"

  update {
    max_parallel     = 1
    min_healthy_time = "10s"
    healthy_deadline = "3m"
  }

  group "redis" {
    count = 1

    constraint {
      attribute = "${node.class}"
      operator  = "="
      value     = "critical"
    }

    network {
      mode = "bridge"

      port "redis" {
        to = 6379
      }
    }

    service {
      name = "redis"
      port = "redis"

      check {
        name     = "redis-health"
        type     = "script"
        task     = "redis"
        command  = "/bin/sh"
        args     = [
          "-c",
          "redis-cli -h 127.0.0.1 -p 6379 -a \"$REDIS_PASSWORD\" ping | grep -q PONG"
        ]
        interval = "10s"
        timeout  = "5s"
      }

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

    vault {
      role = "redis"
    }

    task "redis" {
      driver = "docker"

      config {
        image   = "redis:7-alpine"
        ports   = ["redis"]
        command = "sh"
        args    = ["-c", "redis-server --requirepass \"$REDIS_PASSWORD\" --save '' --appendonly no"]
      }

      # kv/data/{env}/shared/redis — generic path, not cartservice/redis.
      # Any future consumer reads this same path/password rather than
      # getting a cartservice-scoped one.
      template {
        data = <<EOT
{{ with secret "kv/data/shared/redis" }}
REDIS_PASSWORD={{ .Data.data.password }}
{{ end }}
EOT
        destination = "secrets/redis.env"
        env         = true
      }

      resources {
        cpu    = #{Cpu}
        memory = #{Memory}
      }
    }
  }
}
