# nomad-jobs/datastore/postgres.nomad.hcl
#
# Single PostgreSQL instance serving two consumers: metrics-api's
# "metrics" database (Vault-issued dynamic per-connection credentials,
# 1h TTL) and nomad-sentinel's "monitoring" database, agent_anomalies
# table.
#
# Service name is just "postgres" — no environment suffix. Dev and
# prod are entirely separate Nomad clusters and separate Consul
# datacenters; nothing ever shares one catalog where "postgres" could
# collide between them. The env-specific naming that matters (for
# Vault, the one consumer that genuinely needs simultaneous access to
# both) lives at the DNS layer (postgres-dev/postgres-prod hostnames
# on traefik-internal) — a different mechanism entirely, not the
# Consul service name.
#
# Bootstrap credentials live at ONE shared path, kv/data/shared/postgres/admin
# (not per-environment) — matches vault_consumers' actual kv_paths
# entry, which grants that literal path with no env variant. Both the
# superuser password and the vault-admin password are fields on that
# same secret.
#
# CSI, not host volumes — NOT YET COMPLETE: the GCE Persistent Disk
# CSI driver itself isn't deployed anywhere (needs its own controller +
# node-plugin jobs), and the Nomad client service accounts don't yet
# have the GCE disk-management IAM permissions the driver needs to
# create/attach/detach volumes. This volume block assumes both exist;
# neither does yet.

job "postgres" {
  datacenters = ["#{Datacenter}"]
  namespace   = "#{DeploymentNamespace}"
  type        = "service"

  update {
    max_parallel     = 1
    min_healthy_time = "30s"
    healthy_deadline = "5m"
  }

  group "postgres" {
    count = #{ReplicaCount}

    constraint {
      attribute = "${meta.node_pool_type}"
      operator  = "="
      value     = "on-demand"
    }

    volume "postgres-data" {
      type            = "csi"
      source           = "postgres-data-#{Environment}"
      read_only        = false
      attachment_mode  = "file-system"
      access_mode      = "single-node-writer"
    }

    network {
      mode = "bridge"

      port "db" {
        to = 5432
      }
    }

    service {
      name = "postgres"
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

      connect {
        sidecar_service {}

        # Receiving-only sidecar (no upstreams of its own) — 100/128 is
        # a workable floor. Hardcoded per your ask, not an Octopus var.
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

    task "bootstrap" {
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

      template {
        data = <<EOF
{{ with secret "kv/data/shared/postgres/admin" }}
PGHOST=localhost
PGPORT=5432
PGUSER=postgres
PGPASSWORD={{ .Data.data.superuser_password }}
{{ end }}
EOF
        destination = "secrets/postgres.env"
        env         = true
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
      }

      volume_mount {
        volume      = "postgres-data"
        destination = "/var/lib/postgresql/data"
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
