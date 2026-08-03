# nomad-jobs/operations/postgres-backup.nomad.hcl
#
# This job intentionally connects via Consul DNS rather than Consul
# Connect — not every workload needs to be a mesh participant.
# Establishing a sidecar has real startup overhead and a standing
# resource cost; neither is a good trade for a connection that exists
# once a day for a few seconds. Worth being precise about what this
# isn't: it's not a security exception, since Postgres's real port
# stays reachable directly either way (Connect doesn't lock down a
# service's real listening port unless transparent_proxy is enabled,
# which it isn't here) — this is purely an operational-cost decision.
#
# Daily 03:00 UTC per architecture doc section 10. Dumps both
# databases (metrics, monitoring) in one pass — same instance, same
# credentials, per postgres.nomad.hcl's bootstrap task.
#
# Uses the vault-admin credential (the same one Vault's database
# engine uses to mint dynamic roles) rather than a dedicated
# read-only backup role — genuinely overprivileged for a job that only
# ever reads, flagged here rather than left silent. Reasonable for now
# given this never leaves the private VPC (same trust model already
# accepted for Postgres's own plaintext TCP passthrough), but a
# dedicated read-only role would be the tighter version of this.

job "postgres-backup" {
  datacenters = ["#{Datacenter}"]
  namespace   = "#{DeploymentNamespace}"
  type        = "batch"

  periodic {
    cron             = "0 3 * * *"
    prohibit_overlap = true
    time_zone        = "UTC"
  }

  group "postgres-backup" {
    count = #{ReplicaCount}

    affinity {
      attribute = "${meta.node_pool_type}"
      operator  = "="
      value     = "spot"
      weight    = 50
    }

    vault {
      role = "postgres-backup"
    }

    task "postgres-backup" {
      driver = "docker"

      config {
        image   = "google/cloud-sdk:alpine"
        command = "/bin/sh"
        args    = ["-c", "/local/backup.sh"]
      }

      template {
        data = <<EOF
{{ with secret "kv/data/shared/postgres/admin" }}
PGPASSWORD={{ .Data.data.vault_admin_password }}
{{ end }}
PGHOST=postgres.service.consul
PGPORT=5432
PGUSER=vault-admin
EOF
        destination = "secrets/postgres-backup.env"
        env         = true
      }

      template {
        data = <<EOF
#!/bin/sh
set -eu
apk add --no-cache postgresql16-client >/dev/null
STAMP=$(date +%Y%m%dT%H%M%SZ)
for DB in metrics monitoring; do
  pg_dump "$DB" | gzip > "/local/${DB}-${STAMP}.sql.gz"
done
gcloud storage cp /local/*.sql.gz gs://platform-artifacts/pg-backups/#{Environment}/
EOF
        destination = "local/backup.sh"
        perms       = "0755"
      }

      resources {
        cpu    = #{Cpu}
        memory = #{Memory}
      }
    }
  }
}
