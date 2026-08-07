# nomad-jobs/monitoring/nomad-sentinel.nomad.hcl
#
# Same native blue-green mechanism as metrics-api.nomad.hcl — see that
# file's header comment for the full reasoning. No #{DeploymentSlot}.
#
# REMEDIATION_MODE has no default anywhere in this file, on purpose —
# per architecture doc 7.3, the agent crash-fails at startup if it's
# invalid or unset. #{RemediationMode} must be "execute" in dev's
# Octopus variable set and "propose" in prod's — never implicit. Lives
# in its own plain env {} block along with PORT, since neither of
# these ever rotates.
#
# KV path fixed to kv/data/{env}/nomad-sentinel/config — matches what
# vault_consumers actually grants; the job previously read from
# ai-agent/config, which doesn't match the granted path at all.
#
# #{VaultDbRole} — same pattern as metrics-api.nomad.hcl. db_role in
# vault_consumers is "monitoring" for this consumer; prod resolves to
# the bare name ("monitoring"), dev to "monitoring-dev". Set once per
# environment as a literal Octopus variable, not computed.
#
# NOMAD_TOKEN no longer comes from this KV secret at all — the
# platform uses Nomad Workload Identity by default (see
# nomad_acl_policy.nomad_sentinel), so this job authenticates to
# Nomad's own API using its own signed identity via identity { env = true }
# below, not a static token stored anywhere in Vault. The KV secret's
# actual shape needs updating to match (drop the nomad_token field —
# only gemini_api_key/slack_webhook_url remain).
#
# Two separate template blocks, deliberately: the static KV secrets
# (GEMINI_API_KEY, SLACK_WEBHOOK_URL) rarely change and are fine as
# real env = true vars with the default restart behavior.
# HISTORY_DATABASE_URL is the one dynamic, hourly-rotating value — its
# own template, no env = true, change_mode = "noop" — same reasoning
# as metrics-api.nomad.hcl's DATABASE_URL: the app must read this
# specific file directly on every connection attempt, not os.environ,
# or a rotated credential never actually reaches the running process.

job "nomad-sentinel" {
  datacenters = ["#{Datacenter}"]
  namespace   = "#{DeploymentNamespace}"
  type        = "service"

  update {
    canary            = #{ReplicaCount}
    max_parallel      = #{ReplicaCount}
    min_healthy_time  = "30s"
    healthy_deadline  = "5m"
    progress_deadline = "10m"
    auto_revert       = true
    auto_promote      = false
  }

  group "nomad-sentinel" {
    count = #{ReplicaCount}

    # Monitoring must survive Spot preemption.
    constraint {
      attribute = "${meta.node_pool_type}"
      operator  = "="
      value     = "on-demand"
    }

    network {
      mode = "bridge"

      port "http" {
        to = 8090
      }
    }

    service {
      name = "nomad-sentinel"
      port = "http"

      check {
        type     = "http"
        path     = "/health"
        interval = "10s"
        timeout  = "2s"
      }

      tags = [
        "metrics"
        "traefik.enable=true",
        "traefik.http.routers.nomad-sentinel.rule=Host(`nomad-sentinel-#{Environment}.platform.lefrancis.org`)",
        "traefik.http.routers.nomad-sentinel.entrypoints=internal",
        "traefik.http.routers.nomad-sentinel.tls.certresolver=letsencrypt",
      ]
    }

      connect {
        sidecar_service {
          proxy {
            upstreams {
              destination_name = "postgres"
              local_bind_port  = 5432
            }
          }
        }

        sidecar_task {
          resources {
            cpu    = 100
            memory = 128
          }
        }
      }
    }

    vault {
      role = "nomad-sentinel"
    }

    task "nomad-sentinel" {
      driver = "docker"

      config {
        image = "#{ArtifactRegistry}/nomad-sentinel:#{ImageTag}"
        ports = ["http"]
      }

      # Nomad's own signed workload identity, exposed as NOMAD_TOKEN —
      # the standard env var name the nomad CLI/API client already
      # looks for by convention, so nomad-sentinel's own Nomad-API
      # calls need no special-casing on the app side.
      identity {
        env = true
      }

      env {
        PORT             = "8090"
        REMEDIATION_MODE = "#{RemediationMode}"
      }

      template {
        data = <<EOF
{{ with secret "kv/data/#{Environment}/nomad-sentinel/config" }}
GEMINI_API_KEY={{ .Data.data.gemini_api_key }}
SLACK_WEBHOOK_URL={{ .Data.data.slack_webhook_url }}
{{ end }}
EOF
        destination = "secrets/nomad-sentinel-config.env"
        env         = true
      }

      # File-only, deliberately no env = true — see header comment.
      template {
        data = <<EOF
{{ with secret "database/creds/#{VaultDbRole}" }}
HISTORY_DATABASE_URL=postgresql://{{ .Data.username }}:{{ .Data.password }}@{{ env "NOMAD_UPSTREAM_ADDR_postgres" }}/monitoring?sslmode=disable
{{ end }}
EOF
        destination = "secrets/history-database-url.env"
        change_mode = "noop"
      }

      resources {
        cpu    = #{Cpu}
        memory = #{Memory}
      }
    }
  }
}
