job "postgres" {
  datacenters = ["#{Datacenter}"]
  namespace   = "#{DeploymentNamespace}"
  node_pool   = "on-demand"
  type        = "service"

  update {
    max_parallel     = 1
    min_healthy_time = "30s"
    healthy_deadline = "5m"
  }

  group "postgres" {
    count = 1

    constraint {
      attribute = "${node.class}"
      operator  = "="
      value     = "critical"
    }

    volume "postgres-data" {
      type            = "csi"
      source          = "postgres-data-#{Environment}"
      read_only       = false
      attachment_mode = "file-system"
      access_mode     = "single-node-writer"
    }

    network {
      mode = "bridge"

      port "db" {
        static = 5432
        to = 5432
      }
    }

    service {
      name = "postgres"
      port = "db"

      check {
        name     = "postgres-health"
        type     = "script"
        task     = "postgres"
        command  = "/bin/sh"
        args = [
          "-c",
          "PGPASSWORD=\"$POSTGRES_PASSWORD\" psql -h 127.0.0.1 -U \"$POSTGRES_USER\" -d postgres -c 'SELECT 1' >/dev/null"
        ]
        interval = "10s"
        timeout  = "5s"
      }

      tags = [
        "traefik.enable=true",
        "traefik.tcp.routers.postgres.rule=HostSNI(`*`)",
        "traefik.tcp.routers.postgres.entrypoints=postgres",
      ]

      connect {
        sidecar_service {
          tags = ["traefik.enable=false"]
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
      role = "postgres"
    }

    # Runs once, as root, before the main PostgreSQL task.
    # Fixes CSI volume ownership for the postgres UID/GID.
    # docker run --rm postgres:16-alpine id postgres
    # => uid=70(postgres) gid=70(postgres) groups=70(postgres),70(postgres)
    task "volume-permissions" {
      driver = "docker"

      lifecycle {
        hook    = "prestart"
        sidecar = false
      }

      config {
        image   = "busybox:1.36"
        command = "sh"
        args = [
          "-c",
          <<-EOT
            set -eux

            echo "=== BEFORE ==="
            id
            ls -ld /var/lib/postgresql/data

            chown -R 70:70 /var/lib/postgresql/data

            chmod 700 /var/lib/postgresql/data

            echo "=== AFTER ==="
            ls -ld /var/lib/postgresql/data

            touch /var/lib/postgresql/data/.permissions-test
            rm /var/lib/postgresql/data/.permissions-test
          EOT
        ]
      }

      volume_mount {
        volume      = "postgres-data"
        destination = "/var/lib/postgresql/data"
      }

      resources {
        cpu    = 50
        memory = 64
      }
    }

    task "postgres" {
      driver = "docker"

      config {
        image = "postgres:16-alpine"
        ports = ["db"]
        
        mount {
          type   = "bind"
          source = "local/docker-entrypoint-initdb.d"
          target = "/docker-entrypoint-initdb.d"
        }
      }

      volume_mount {
        volume      = "postgres-data"
        destination = "/var/lib/postgresql/data"
      }

      template {
        data = <<EOF
{{ with secret "kv/data/shared/postgres/admin" }}
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'vault-admin') THEN
    CREATE ROLE "vault-admin" WITH LOGIN CREATEROLE PASSWORD '{{ .Data.data.vault_admin_password }}';
  END IF;
END
$$;

CREATE DATABASE metrics OWNER "vault-admin";
CREATE DATABASE monitoring OWNER "vault-admin";
{{ end }}
EOF
        destination = "local/docker-entrypoint-initdb.d/bootstrap.sql"
      }

      template {
        data = <<EOF
{{ with secret "kv/data/shared/postgres/admin" }}
POSTGRES_PASSWORD={{ .Data.data.superuser_password }}
{{ end }}
POSTGRES_USER=postgres
PGDATA=/var/lib/postgresql/data/pgdata
EOF
        destination = "secrets/postgres.env"
        env         = true
      }

      resources {
        cpu    = #{Cpu}
        memory = #{Memory}
      }
    }
  }
}