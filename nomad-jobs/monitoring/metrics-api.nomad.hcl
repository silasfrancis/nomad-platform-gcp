# nomad-jobs/monitoring/metrics-api.nomad.hcl
#
# Blue-green per the architecture doc — but flagging something real
# rather than quietly working around it: the doc's own Traefik routing
# table (section 4.3) has no entry for metrics-api at all, and nothing
# else in this project calls it by a stable hostname that would need a
# blue/green pointer flipped (Prometheus just scrapes whatever's
# registered in Consul). The two-parallel-job-names mechanic below is
# built to match what the doc describes, but what the "switch" is
# actually switching *for* isn't resolved — worth a docs pass, not
# something I want to silently paper over here.
#
# #{DeploymentSlot} is "-blue" or "-green" (Octopus variable) — each
# release alternates which one it deploys as, per architecture doc 6.5.
#
# DATABASE_URL is Vault's dynamic 1h-TTL credential
# (database/creds/#{Environment}-metrics-api). change_mode = "noop" on
# that template deliberately does NOT restart the process on rotation
# — the app re-reads the env var fresh on every connection attempt
# (never caches it at import time), so an in-place file rewrite is all
# that's needed. A restart here would be actively wrong: it'd revoke
# the very credential a live connection might be using mid-request.

job "metrics-api#{DeploymentSlot}" {
  datacenters = ["#{Datacenter}"]
  namespace   = "monitoring"
  type        = "service"

  update {
    max_parallel     = 1
    min_healthy_time = "10s"
    healthy_deadline = "3m"
    auto_revert      = true
  }

  group "metrics-api" {
    count = 1

    # Stateful/Vault-credential-dependent.
    constraint {
      attribute = "${meta.node_pool_type}"
      operator  = "="
      value     = "on-demand"
    }

    network {
      port "http" {
        to = 8080
      }
    }

    vault {
      role       = "metrics-api-#{Environment}"
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
DATABASE_URL=postgresql://{{ .Data.username }}:{{ .Data.password }}@postgres-#{Environment}.service.consul:5432/metrics?sslmode=disable
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
      }
    }
  }
}
