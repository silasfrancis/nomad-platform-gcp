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
gcloud storage cp /local/*.sql.gz gs://nomad-platform-gcp-europe-west1-platform-artifacts/pg-backups/#{Environment}/
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
