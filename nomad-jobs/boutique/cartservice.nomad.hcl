job "cartservice" {
  datacenters = ["#{Datacenter}"]
  namespace   = "#{DeploymentNamespace}"
  node_pool   = "on-demand"
  type        = "service"

  update {
    max_parallel      = 1
    canary            = 1
    min_healthy_time  = "30s"
    healthy_deadline  = "5m"
    progress_deadline = "10m"
    auto_revert       = true
    auto_promote      = false
  }

  group "cartservice" {
    count = #{ReplicaCount}

    constraint {
      attribute = "${node.class}"
      operator  = "="
      value     = "critical"
    }

    network {
      mode = "bridge"

      port "grpc" {
        to = 7070
      }
    }

    service {
      name = "cartservice"
      port = 7070

      check {
        type     = "grpc"
        port     = "grpc"
        interval = "10s"
        timeout  = "2s"
      }

      tags = [
        "metrics"
      ]

      connect {
        sidecar_service {}

        # One upstream — 100/128 floor.
        sidecar_task {
          resources {
            cpu    = 100
            memory = 128
          }
        }
      }
    }

    vault {
      role = "cartservice"
    }

    task "cartservice" {
      driver = "docker"

      config {
        image = "#{ArtifactRegistry}/cartservice:#{ImageTag}"
        ports = ["grpc"]
      }

      # REDIS_ADDR is passed straight to StackExchange.Redis's own
      # connection string parser — no custom parsing in app code, per
      # architecture doc 5.2. {{ env "NOMAD_UPSTREAM_ADDR_redis" }}
      # resolves to the sidecar's local_bind_port at render time —
      # used instead of hardcoding localhost:6379 so it can't drift
      # out of sync with the upstream block above.
      template {
        data = <<EOF
{{ with secret "kv/data/shared/redis" }}
REDIS_ADDR=redis.service.consul:6379,password={{ .Data.data.password }}
{{ end }}
PORT=7070
EOF
        destination = "secrets/cartservice.env"
        env         = true
      }

      resources {
        cpu    = #{Cpu}
        memory = #{Memory}
      }
    }
  }
}

