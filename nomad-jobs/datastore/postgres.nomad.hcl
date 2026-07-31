# nomad-jobs/datastore/postgres.nomad.hcl
#
# Single PostgreSQL instance serving two consumers: metrics-api's
# "metrics" database (Vault-issued dynamic per-connection credentials,
# 1h TTL) and nomad-sentinel's "monitoring" database, agent_anomalies
# table (see modules/vault/engines.tf for both connection configs).
#
# #{Datacenter}/#{Environment}/#{PostgresCpu}/#{PostgresMemory} are
# Octopus variables, substituted at deploy time — same job spec
# promoted dev -> prod unchanged, per the architecture doc's promotion
# flow.
#
# NOT YET dedicated-node-scheduled. Known limitation, tracked as a
# changelog item: this only hard-constrains to on-demand nodes, same
# as any other stateful service — it does not yet guarantee the same
# specific node across reschedules. See docs/CHANGELOG.md once it
# exists.

job "postgres" {
  datacenters = ["#{Datacenter}"]
  namespace   = "datastore"
  type        = "service"

  # Postgres itself doesn't get an update strategy in the canary/
  # rolling/blue-green sense used elsewhere in this project — there's
  # exactly one instance, no traffic-shifting rollout makes sense for
  # a stateful database with a single replica.
  update {
    max_parallel     = 1
    min_healthy_time = "30s"
    healthy_deadline = "5m"
  }

  group "postgres" {
    count = 1

    # Stateful — same hard on-demand constraint as every other
    # stateful/Vault-credential-dependent workload in this project.
    constraint {
      attribute = "${meta.node_pool_type}"
      operator  = "="
      value     = "on-demand"
    }

    volume "postgres-data" {
      type      = "host"
      source    = "postgres-data-#{Environment}"
      read_only = false
    }

    network {
      port "db" {
        static = 5432
      }
    }

    # Nomad Workload Identity — no static Vault token anywhere in this
    # job spec. The role name here must match the "postgres" entry in
    # modules/vault/locals.tf's vault_consumers map (namespace +
    # job_id bound in that role's claims).
    vault {
      role = "postgres-#{Environment}"
    }

    task "bootstrap" {
      # Runs once before "postgres" starts on every placement (not
      # just the first), then exits — Nomad's native equivalent of a
      # Kubernetes init container. Idempotent on purpose: every SQL
      # statement below is IF NOT EXISTS/OR REPLACE, since this task
      # re-runs on every reschedule, not just the first deploy.
      lifecycle {
        hook    = "prestart"
        sidecar = false
      }

      driver = "docker"

      config {
        image   = "postgres:16-alpine"
        command = "/bin/sh"
        args    = ["-c", "psql -v ON_ERROR_STOP=1 -f /local/bootstrap.sql"]
      }

      # Superuser credentials — the one static (non-Vault-dynamic)
      # secret in this whole job, since something has to have enough
      # privilege to create the vault-admin role in the first place.
      # Rotated manually; not on the dynamic-credential rotation path
      # metrics-api/nomad-sentinel use.
      template {
        data = <<EOF
{{ with secret "kv/data/#{Environment}/postgres/superuser" }}
PGHOST=localhost
PGPORT=5432
PGUSER=postgres
PGPASSWORD={{ .Data.data.password }}
{{ end }}
EOF
        destination = "secrets/postgres.env"
        env         = true
      }

      # vault-admin: CREATEROLE-privileged, used by Vault's database
      # secrets engine to mint the short-lived dynamic roles metrics-api
      # gets at connection time — never handed out directly. Its own
      # password is itself Vault-managed (kv/data/#{Environment}/postgres/vault-admin),
      # rotated independently of the superuser credential above.
      template {
        data = <<EOF
{{ with secret "kv/data/#{Environment}/postgres/vault-admin" }}
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'vault-admin') THEN
    CREATE ROLE "vault-admin" WITH LOGIN CREATEROLE PASSWORD '{{ .Data.data.password }}';
  END IF;
END
$$;

CREATE DATABASE metrics OWNER "vault-admin";
CREATE DATABASE monitoring OWNER "vault-admin";
EOF
        destination = "local/bootstrap.sql"
      }

      resources {
        cpu    = 100
        memory = 128
      }
    }

    task "postgres" {
      driver = "docker"

      config {
        image = "postgres:16-alpine"
        ports = ["db"]
        volumes = [
          "postgres-data:/var/lib/postgresql/data",
        ]
      }

      template {
        data = <<EOF
{{ with secret "kv/data/#{Environment}/postgres/superuser" }}
POSTGRES_PASSWORD={{ .Data.data.password }}
{{ end }}
POSTGRES_USER=postgres
PGDATA=/var/lib/postgresql/data/pgdata
EOF
        destination = "secrets/postgres.env"
        env         = true
      }

      resources {
        cpu    = #{PostgresCpu}
        memory = #{PostgresMemory}
      }

      # See docs/CHANGELOG.md (once written) for why this is plain TCP,
      # not TLS passthrough — deliberate for now, not an oversight.
      service {
        name = "postgres-#{Environment}"
        port = "db"

        check {
          type     = "tcp"
          port     = "db"
          interval = "10s"
          timeout  = "2s"
        }

        tags = [
          "traefik.enable=true",
          "traefik.tcp.routers.postgres.rule=HostSNI(`*`)",
          "traefik.tcp.routers.postgres.entrypoints=postgres",
          "traefik.tcp.services.postgres.loadbalancer.server.port=5432",
        ]
      }
    }
  }
}
