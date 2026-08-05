# nomad-jobs/monitoring/metrics-api.nomad.hcl
#
# Blue-green via Nomad's own native mechanism — canary set equal to
# count, not a separate job name. This resolves the ambiguity flagged
# earlier (no Traefik route exists for this service, so a Traefik-side
# blue/green pointer flip was never actually the right mechanism): the
# new version runs fully alongside the old one under the SAME job/
# service name, gets validated, and `nomad job promote` cuts over
# atomically by tearing down every old allocation. No #{DeploymentSlot}
# variable needed anywhere.
#
# Vault role is bare "metrics-api" — no environment suffix. Dev/prod
# separation happens because they're registered under two entirely
# separate JWT backends (jwt-nomad-dev vs jwt-nomad-prod), not because
# the role name itself varies.
#
# #{VaultDbRole} is a new per-(project,environment) Octopus variable —
# db_role in vault_consumers is "metrics-api", and the actual Vault
# database role name follows an asymmetric convention: prod gets the
# bare name ("metrics-api"), dev gets a "-dev" suffix ("metrics-api-dev").
# That's not something Octopus's plain text substitution can compute
# via a ternary, so it's a literal value set once per environment
# rather than derived.
#
# Connect mesh: one upstream (postgres, no environment suffix — see
# postgres.nomad.hcl for why). Using NOMAD_UPSTREAM_ADDR_postgres
# rather than hardcoding localhost:5432 removes any chance of the
# local_bind_port and the app's env var silently drifting out of sync.
#
# DATABASE_URL correctness fix: this template has NO env = true. Nomad
# documents plainly that env = true + change_mode = "noop" is silently
# a no-op for updates — the file gets rewritten with the new
# credential when Vault rotates the lease, but a running container's
# actual environment is fixed at exec time and never updates live.
# Since we deliberately don't want a restart on every 1h rotation, the
# app itself must read this file directly off disk on every new
# connection attempt (not os.environ) — this is the "read fresh, never
# cached" behavior the architecture doc describes, now actually wired
# correctly rather than just described that way. PORT lives in its own
# plain env {} block instead, since it never changes and doesn't need
# any of this.

job "metrics-api" {
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
      name = "metrics-api"
      port = "http"

      check {
        type     = "http"
        path     = "/health"
        interval = "10s"
        timeout  = "2s"
      }

      tags = [
        "traefik.enable=true",
        "traefik.http.routers.metrics-api.rule=Host(`metrics-api-#{Environment}.platform.lefrancis.org`)",
        "traefik.http.routers.metrics-api.entrypoints=internal",
        "traefik.http.routers.metrics-api.tls.certresolver=letsencrypt",
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

        # One upstream, receiving-only otherwise — 100/128 floor.
        sidecar_task {
          resources {
            cpu    = 100
            memory = 128
          }
        }
      }
    }

    vault {
      role = "metrics-api"
    }

    task "metrics-api" {
      driver = "docker"

      config {
        image = "#{ArtifactRegistry}/metrics-api:#{ImageTag}"
        ports = ["http"]
      }

      env {
        PORT = "8080"
      }

      # File-only, deliberately no env = true — see header comment.
      # The app must read this file directly on every connection
      # attempt to actually pick up a rotated credential.
      template {
        data = <<EOF
{{ with secret "database/creds/#{VaultDbRole}" }}
DATABASE_URL=postgresql://{{ .Data.username }}:{{ .Data.password }}@{{ env "NOMAD_UPSTREAM_ADDR_postgres" }}/metrics?sslmode=disable
{{ end }}
EOF
        destination = "secrets/database-url.env"
        change_mode = "noop"
      }

      resources {
        cpu    = #{Cpu}
        memory = #{Memory}
      }
    }
  }
}
