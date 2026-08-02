# nomad-jobs/datastore/postgres.nomad.hcl
#
# Single PostgreSQL instance serving two consumers: metrics-api's
# "metrics" database (Vault-issued dynamic per-connection credentials,
# 1h TTL) and nomad-sentinel's "monitoring" database, agent_anomalies
# table.
#
# Connect mesh retrofit: group-level service {}, receiving-only for
# metrics-api/nomad-sentinel — both now reach this via their own
# upstream, not Consul DNS. The traefik.* tags stay on this SAME
# service block, unchanged — those are for Vault's own connection
# (external to this Nomad cluster entirely, on mgmt-vm, no local
# Consul agent, hence the TCP passthrough through traefik-internal).
# Two different consumers, two different access paths, one service
# registration serving both — Connect doesn't replace or conflict with
# the passthrough, it's an entirely separate concern layered on top.
#
# NOT YET dedicated-node-scheduled. Known limitation, tracked as a
# changelog item — see docs/CHANGELOG.md once it exists.

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
      type      = "host"
      source    = "postgres-data-#{Environment}"
      read_only = false
    }

    network {
      mode = "bridge"

      port "db" {
        to = 5432
      }
    }

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

      connect {
        sidecar_service {}
      }
    }

    vault {
      role = "postgres-#{Environment}"
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
        cpu    = #{Cpu}
        memory = #{Memory}
      }
    }
  }
}
