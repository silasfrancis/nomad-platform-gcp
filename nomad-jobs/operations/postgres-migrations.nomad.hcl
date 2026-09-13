job "postgres-migrations" {
  datacenters = ["#{Datacenter}"]
  namespace   = "#{DeploymentNamespace}"
  node_pool   = "on-demand"
  type        = "batch"

  group "migrate" {
    network {}

    service {
      name = "postgres-migrate"
    }

    vault {
      role = "postgres-migrations"
    }

    task "monitoring-agent-anomalies" {
      driver = "docker"

      config {
        image   = "postgres:16-alpine"
        command = "psql"
        args = [
          "-U", "postgres",
          "-d", "postgres",
          "-f", "/local/migrate.sql"
        ]
      }

      template {
        data = <<EOF
{{ range service "postgres" }}
PGHOST={{ .Address }}
PGPORT={{ .Port }}
{{ end }}
{{ with secret "kv/data/shared/postgres/admin" }}
PGPASSWORD={{ .Data.data.superuser_password }}
{{ end }}
EOF
        destination = "secrets/pg.env"
        env         = true
      }

      template {
        data = <<EOF
-- Cluster-wide: create a dedicated, non-login owner role and let vault-admin manage membership in it.
-- vault-admin can't be granted membership in itself (Postgres rejects
-- self-membership grants outright), so a separate owner role is what
-- vault-admin's dynamic creation_statements grant into for every
-- freshly minted ephemeral role instead.
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'monitoring-owner') THEN
    CREATE ROLE "monitoring-owner" NOLOGIN;
  END IF;
END
$$;

GRANT "monitoring-owner" TO "vault-admin" WITH ADMIN OPTION;

\c monitoring

-- Creates agent_anomalies (matching history.py's schema exactly) and
-- assigns ownership to monitoring-owner up front, so nomad-sentinel's
-- own ensure_schema() CREATE TABLE/INDEX IF NOT EXISTS calls become
-- no-ops regardless of whether nomad-sentinel has ever run in this
-- environment. Every ephemeral role vault-admin creates is granted
-- monitoring-owner membership (see the monitoring Vault role's
-- creation_statements), which is what gives it ownership-equivalent
-- access here.
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

ALTER TABLE agent_anomalies OWNER TO "monitoring-owner";
ALTER SEQUENCE agent_anomalies_id_seq OWNER TO "monitoring-owner";

-- Add a new table block above this line as needed. Use \c to switch
-- databases first if it's not in monitoring.
EOF
        destination = "local/migrate.sql"
      }

      resources {
        cpu    = 100
        memory = 128
      }
    }
  }
}