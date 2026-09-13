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
    }

    vault {
      role = "postgres"
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
