# nomad-jobs/boutique/cartservice.nomad.hcl
#
# Canary deployment, on-demand only (direct customer transaction
# path). Reads the shared Redis instance's password from Vault —
# kv/data/{env}/shared/redis, not a cartservice-specific path, since
# that KV path was generalized for future consumers (see chat).

job "cartservice" {
  datacenters = ["#{Datacenter}"]
  namespace   = "boutique"
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
    count = 1

    constraint {
      attribute = "${meta.node_pool_type}"
      operator  = "="
      value     = "on-demand"
    }

    network {
      port "grpc" {
        to = 7070
      }
    }

    vault {
      role = "cartservice-#{Environment}"
    }

    task "cartservice" {
      driver = "docker"

      config {
        image = "#{ArtifactRegistry}/cartservice:#{ImageTag}"
        ports = ["grpc"]
      }

      # REDIS_ADDR is passed straight to StackExchange.Redis's own
      # connection string parser — no custom parsing in app code, per
      # architecture doc 5.2.
      template {
        data = <<EOF
{{ with secret "kv/data/#{Environment}/shared/redis" }}
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

      service {
        name = "cartservice"
        port = "grpc"

        check {
          type     = "grpc"
          port     = "grpc"
          interval = "10s"
          timeout  = "2s"
        }
      }
    }
  }
}
