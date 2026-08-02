# nomad-jobs/boutique/cartservice.nomad.hcl
#
# Canary deployment, on-demand only (direct customer transaction
# path). Connect mesh retrofit: group-level service {}, one upstream
# (redis) — Connect proxies plain TCP fine, not just HTTP/gRPC, so
# Redis's wire protocol works the same way through the sidecar as
# everything else here. REDIS_ADDR now points at
# localhost:<local_bind_port> instead of Consul DNS; the password
# still comes from kv/data/{env}/shared/redis exactly as before —
# Connect handles the network hop, not authentication.

job "cartservice" {
  datacenters = ["#{Datacenter}"]
  namespace   = "#{DeploymentNamespace}"
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
      attribute = "${meta.node_pool_type}"
      operator  = "="
      value     = "on-demand"
    }

    network {
      mode = "bridge"

      port "grpc" {
        to = 7070
      }
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

      connect {
        sidecar_service {
          proxy {
            upstreams {
              destination_name = "redis"
              local_bind_port  = 6379
            }
          }
        }
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
      # architecture doc 5.2. localhost:6379 here is the sidecar's
      # local_bind_port, not Redis's own port directly.
      template {
        data = <<EOF
{{ with secret "kv/data/#{Environment}/shared/redis" }}
REDIS_ADDR=localhost:6379,password={{ .Data.data.password }}
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
