# nomad-jobs/operations/loadgenerator.nomad.hcl
#
# Moved from boutique/ to operations/, and from an always-on service
# to a real batch job — Locust now runs for a fixed duration
# (--run-time) and exits, rather than generating continuous
# traffic indefinitely. That's what actually makes `type = "batch"`
# correct here: batch jobs are for finite-duration work, and an
# always-on Locust process was never really a good fit for that job
# type even before the move.
#
# No periodic {} stanza — this is dispatched on demand (`nomad job run`
# or `nomad job dispatch`, e.g. as a smoke-test/load-validation step
# during a deployment), not run on a fixed schedule the way
# consul-snapshot.nomad.hcl/postgres-backup.nomad.hcl are. Add one if
# you actually want it to run automatically on a cadence instead.
#
# Removed from the Connect mesh entirely — no network {}, service {},
# or connect {} block. FRONTEND_ADDR goes back to plain Consul DNS
# (frontend.service.consul:8080), the same mechanism every job used
# before this session's mesh retrofit. This was the one file flagged
# as a genuinely unverified edge case in that retrofit (no real
# inbound port, uncertain whether Nomad's Connect model even wants a
# service like this to have a sidecar) — moving it out of the mesh
# entirely resolves that uncertainty by removing the question, not by
# answering it.

job "loadgenerator" {
  datacenters = ["#{Datacenter}"]
  namespace   = "#{DeploymentNamespace}"
  type        = "batch"

  group "loadgenerator" {
    count = #{ReplicaCount}

    constraint {
      attribute = "${meta.node_pool_type}"
      operator  = "="
      value     = "spot"
    }

    task "loadgenerator" {
      driver = "docker"

      config {
        image = "#{ArtifactRegistry}/loadgenerator:#{ImageTag}"
      }

      env {
        FRONTEND_ADDR   = "frontend.service.consul:8080"
        USERS           = "10"
        SPAWN_RATE      = "1"
        LOCUST_HEADLESS = "true"
        RUN_TIME        = "#{RunTime}" # e.g. "5m" — new Octopus variable, this job's own duration
      }

      resources {
        cpu    = #{Cpu}
        memory = #{Memory}
      }
    }
  }
}
