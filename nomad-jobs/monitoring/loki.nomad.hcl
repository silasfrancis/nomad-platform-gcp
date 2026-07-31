# nomad-jobs/monitoring/loki.nomad.hcl
#
# One instance per environment — receives logs from that
# environment's Grafana Alloy instances only. Config templated inline
# and substituted by Octopus at deploy time, same reasoning and same
# exception-to-the-bake-into-image-pattern as prometheus.nomad.hcl.

job "loki" {
  datacenters = ["#{Datacenter}"]
  namespace   = "#{DeploymentNamespace}"
  type        = "service"

  update {
    max_parallel     = 1
    min_healthy_time = "10s"
    healthy_deadline = "3m"
    auto_revert      = true
  }

  group "loki" {
    count = #{ReplicaCount}

    constraint {
      attribute = "${meta.node_pool_type}"
      operator  = "="
      value     = "on-demand"
    }

    volume "loki-data" {
      type      = "host"
      source    = "loki-data-#{Environment}"
      read_only = false
    }

    network {
      port "http" {
        to = 3100
      }
    }

    task "loki" {
      driver = "docker"

      config {
        image   = "grafana/loki:3.3.2"
        ports   = ["http"]
        args    = ["-config.file=/local/loki.yml"]
        volumes = ["loki-data:/loki"]
      }

      template {
        data = <<EOF
auth_enabled: false

server:
  http_listen_port: 3100

common:
  path_prefix: /loki
  storage:
    filesystem:
      chunks_directory: /loki/chunks
      rules_directory: /loki/rules
  replication_factor: 1
  ring:
    kvstore:
      store: inmemory

schema_config:
  configs:
    - from: 2024-01-01
      store: tsdb
      object_store: filesystem
      schema: v13
      index:
        prefix: index_
        period: 24h

limits_config:
  retention_period: 720h
EOF
        destination = "local/loki.yml"
      }

      resources {
        cpu    = #{Cpu}
        memory = #{Memory}
      }

      service {
        name = "loki"
        port = "http"

        check {
          type     = "http"
          path     = "/ready"
          interval = "10s"
          timeout  = "2s"
        }
      }
    }
  }
}
