job "postgres-backup" {
  datacenters = ["#{Datacenter}"]
  namespace   = "#{DeploymentNamespace}"
  node_pool   = "on-demand"
  type        = "batch"

  periodic {
    cron             = "0 3 * * *"
    prohibit_overlap = true
    time_zone        = "UTC"
  }

  group "postgres-backup" {
    count = #{ReplicaCount}

    affinity {
      attribute = "${node.class}"
      operator  = "="
      value     = "preemptible"
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
{{ $cred := . }}
{{ range service "postgres" }}
PGPASSWORD={{ $cred.Data.data.vault_admin_password }}
PGHOST={{ .Address }}
PGPORT={{ .Port }}
PGUSER=vault-admin
{{ end }}
{{ end }}
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
  gsutil cp "/local/${DB}-${STAMP}.sql.gz" gs://#{PlatformGcsBucket}/pg-backups/#{Environment}/
done
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
