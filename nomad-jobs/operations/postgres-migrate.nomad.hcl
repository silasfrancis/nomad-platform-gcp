job "postgres-migrate" {
  datacenters = ["#{Datacenter}"]
  namespace   = "#{DeploymentNamespace}"
  node_pool   = "on-demand"
  type        = "batch"

  group "migrate" {
    network {
      mode = "bridge"
    }

    service {
      name = "postgres-migrate"
      connect {
        sidecar_service {
          proxy {
            upstreams {
              destination_name = "postgres"
              local_bind_port  = 5432
            }
          }
        }
      }
    }

    vault {
      role = "postgres"
    }

    task "migrate" {
      driver = "docker"

      config {
        image   = "postgres:16-alpine"
        command = "psql"
        args    = ["-h", "127.0.0.1", "-p", "5432", "-U", "postgres", "-d", "postgres", "-f", "/local/migrate.sql"]
      }

      template {
        data = <<EOF
\c monitoring

-- One-time ownership fix for tables that were created under a
-- since-expired Vault dynamic role, before vault-admin membership
-- was granted to every monitoring-#{Environment} lease. Safe to
-- re-run: both blocks are existence-guarded no-ops once applied.
DO $$
BEGIN
  IF EXISTS (SELECT FROM pg_tables WHERE schemaname = 'public' AND tablename = 'agent_anomalies') THEN
    ALTER TABLE agent_anomalies OWNER TO "vault-admin";
  END IF;
  IF EXISTS (SELECT FROM pg_class WHERE relname = 'agent_anomalies_id_seq') THEN
    ALTER SEQUENCE agent_anomalies_id_seq OWNER TO "vault-admin";
  END IF;
END $$;

-- Add a new guarded block above this line for each future table
-- that ends up owned by whatever ephemeral Vault role created it
-- first. Use \c to switch databases first if it's not in monitoring.
EOF
        destination = "local/migrate.sql"
      }

      template {
        data = <<EOF
{{ with secret "kv/data/shared/postgres/admin" }}
PGPASSWORD={{ .Data.data.superuser_password }}
{{ end }}
EOF
        destination = "secrets/pg.env"
        env         = true
      }

      resources {
        cpu    = 100
        memory = 128
      }
    }
  }
}