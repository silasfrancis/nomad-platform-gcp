# nomad-jobs/monitoring/metrics-api.nomad.hcl
#
# Blue-green per the architecture doc — but flagging something real
# rather than quietly working around it: the doc's own Traefik routing
# table (section 4.3) has no entry for metrics-api at all, and nothing
# else in this project calls it by a stable hostname that would need a
# blue/green pointer flipped. The two-parallel-job-names mechanic below
# is built to match what the doc describes, but what the "switch" is
# actually switching *for* isn't resolved — worth a docs pass.
#
# Connect mesh retrofit: group-level service {}, one upstream
# (postgres-#{Environment}) — after Octopus's own substitution this
# resolves to a literal Consul service name like "postgres-dev", which
# is exactly what destination_name needs (a name Consul actually knows
# about, not a Nomad-side variable).
#
# DATABASE_URL is Vault's dynamic 1h-TTL credential
# (database/creds/#{Environment}-metrics-api), now pointed at
# localhost:5432 (the sidecar's local_bind_port) instead of Consul DNS.
# change_mode = "noop" on that template deliberately does NOT restart
# the process on rotation — the app re-reads the env var fresh on every
# connection attempt, so an in-place file rewrite is all that's needed.

job "metrics-api#{DeploymentSlot}" {
  datacenters = ["#{Datacenter}"]
  namespace   = "#{DeploymentNamespace}"
  type        = "service"

  update {
    max_parallel     = 1
    min_healthy_time = "10s"
    healthy_deadline = "3m"
    auto_revert      = true
  }

  group "metrics-api" {
    count = #{ReplicaCount}

    constraint {
      attribute = "${meta.node_pool_type}"
      operator  = "="
      value     = "on-demand"
    }

    network {
      mode = "bridge"

      port "http" {
        to = 8080
      }
    }

    service {
      name = "metrics-api#{DeploymentSlot}"
      port = "http"

      check {
        type     = "http"
        path     = "/health"
        interval = "10s"
        timeout  = "2s"
      }

      tags = ["metrics"]

      connect {
        sidecar_service {
          proxy {
            upstreams {
              destination_name = "postgres-#{Environment}"
              local_bind_port  = 5432
            }
          }
        }
      }
    }

    vault {
      role        = "metrics-api-#{Environment}"
      change_mode = "noop"
    }

    task "metrics-api" {
      driver = "docker"

      config {
        image = "#{ArtifactRegistry}/metrics-api:#{ImageTag}"
        ports = ["http"]
      }

      template {
        data = <<EOF
{{ with secret "database/creds/#{Environment}-metrics-api" }}
DATABASE_URL=postgresql://{{ .Data.username }}:{{ .Data.password }}@localhost:5432/metrics?sslmode=disable
{{ end }}
PORT=8080
EOF
        destination = "secrets/metrics-api.env"
        env         = true
        change_mode = "noop"
      }

      resources {
        cpu    = #{Cpu}
        memory = #{Memory}
      }
    }
  }
}
