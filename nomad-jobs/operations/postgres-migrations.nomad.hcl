job "postgres-migrations" {
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
      role = "postgres-migrations"
    }

    task "monitoring-agent-anomalies" {
      driver = "docker"

      config {
        image   = "postgres:16-alpine"
        command = "psql"
        args    = ["-h", "127.0.0.1", "-p", "5432", "-U", "postgres", "-d", "postgres", "-f", "/local/migrate.sql"]
      }

      template {
        data = <<EOF
\c monitoring

-- Creates agent_anomalies (matching history.py's schema exactly) and
-- assigns ownership to vault-admin up front, so nomad-sentinel's own
-- ensure_schema() CREATE TABLE/INDEX IF NOT EXISTS calls become no-ops
-- regardless of whether nomad-sentinel has ever run in this environment.
CREATE TABLE IF NOT EXISTS agent_anomalies (
    id                  SERIAL PRIMARY KEY,
    environment         TEXT NOT NULL,
    detected_at         TIMESTAMPTZ NOT NULL,
    job_id              TEXT NOT NULL,
    alloc_id            TEXT NOT NULL,
    task                TEXT NOT NULL,
    namespace           TEXT NOT NULL,
    anomaly_type        TEXT NOT NULL,
    restarts            INTEGER NOT NULL DEFAULT 0,
    likely_cause        TEXT,
    severity            TEXT,
    confidence          REAL,
    suggested_action    TEXT,
    remediation_mode    TEXT NOT NULL,
    outcome             TEXT NOT NULL,
    outcome_detail      JSONB
);

CREATE INDEX IF NOT EXISTS idx_agent_anomalies_job_detected
    ON agent_anomalies (job_id, detected_at DESC);

ALTER TABLE agent_anomalies OWNER TO "vault-admin";
ALTER SEQUENCE agent_anomalies_id_seq OWNER TO "vault-admin";

-- Add a new table block above this line as needed. Use \c to switch
-- databases first if it's not in monitoring.
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