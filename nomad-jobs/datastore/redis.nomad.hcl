# nomad-jobs/datastore/redis.nomad.hcl
#
# Shared Redis instance — cartservice is the only real consumer today,
# but the job/service/Vault path are named generically (not
# cartservice-specific) so a future consumer can share this instance
# without a rename. No host volume, deliberately — matches the
# upstream Online Boutique K8s manifest's emptyDir{}: cart data is
# intentionally ephemeral and resets on restart.
#
# NOTE — single shared password, no per-consumer isolation: --requirepass
# is one secret for the whole instance. Fine with exactly one consumer;
# if a second service actually starts using this instance, it gets full
# access to every key including cartservice's. Redis ACL users (6+),
# each scoped to their own key pattern, is the real fix — tracked as a
# changelog item, not built now since there's no second consumer yet.
#
# Needs its own Vault workload-identity role, separate from
# cartservice's — Vault's JWT auth binds by exact nomad_job_id, so
# cartservice's own modules/vault/locals.tf entry doesn't cover this
# job. Add a "redis" entry to vault_consumers, namespace = "datastore".

job "redis" {
  datacenters = ["#{Datacenter}"]
  namespace   = "#{DeploymentNamespace}"
  type        = "service"

  update {
    max_parallel     = 1
    min_healthy_time = "10s"
    healthy_deadline = "3m"
  }

  group "redis" {
    count = #{ReplicaCount}

    # Stateful — same hard on-demand constraint as Postgres. A restart
    # on Spot would just mean cartservice's cart data resets (matches
    # upstream's already-ephemeral design), but on-demand keeps that
    # from happening on every routine Spot preemption rather than only
    # on a real restart.
    constraint {
      attribute = "${meta.node_pool_type}"
      operator  = "="
      value     = "on-demand"
    }

    network {
      port "redis" {
        static = 6379
      }
    }

    vault {
      role = "redis-#{Environment}"
    }

    task "redis" {
      driver = "docker"

      config {
        image   = "redis:7-alpine"
        ports   = ["redis"]
        command = "sh"
        args    = ["-c", "redis-server --requirepass \"$REDIS_PASSWORD\" --save '' --appendonly no"]
      }

      # kv/data/{env}/shared/redis — generic path, not cartservice/redis.
      # Any future consumer reads this same path/password rather than
      # getting a cartservice-scoped one.
      template {
        data = <<EOT
{{ with secret "kv/data/#{Environment}/shared/redis" }}
REDIS_PASSWORD={{ .Data.data.password }}
{{ end }}
EOT
        destination = "secrets/redis.env"
        env         = true
      }

      resources {
        cpu    = 100
        memory = 128
      }

      service {
        name = "redis"
        port = "redis"

        check {
          type     = "tcp"
          port     = "redis"
          interval = "10s"
          timeout  = "2s"
        }

        # No traefik.enable tag — Redis is never routed through
        # Traefik. Consumers reach it directly via Consul DNS
        # (redis.service.consul:6379), same as any other internal
        # service-to-service call in this project.
      }
    }
  }
}
