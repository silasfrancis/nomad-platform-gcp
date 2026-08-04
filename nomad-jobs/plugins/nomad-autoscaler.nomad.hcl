# nomad-jobs/plugins/nomad-autoscaler.nomad.hcl
#
# One instance per environment — manages both scaling mechanisms
# documented in the architecture doc 2.5:
#
# Task scaling (frontend's HPA-equivalent): needs NO configuration
# here at all. The Autoscaler discovers frontend's own scaling {}
# block via the Nomad API automatically; the agent config below only
# needs to know Prometheus exists as an APM source.
#
# Cluster scaling (MIG resize): needs one policy per MIG, hardcoded
# into the agent config's own scaling blocks (not derived from
# anything in a job spec) — 4 MIGs total across both environments, 2
# per environment (ondemand + spot), so this job's own config only
# ever references its own 2. #{OndemandMigName}/#{SpotMigName} are new
# Octopus variables holding the literal MIG names from compute/main.tf.
#
# NOT YET BUILT, TWO SEPARATE PIECES:
#
# 1. Vault's GCP secrets engine — nothing in modules/vault/engines.tf
#    mounts one yet. The gce-mig target plugin's own docs specifically
#    recommend Vault-issued short-lived credentials via a template,
#    not a static key file or env var — that's what the vault {} block
#    and template below assume exists, but it doesn't yet.
#
# 2. This job's own Nomad ACL policy — the plugin's docs state a Nomad
#    ACL token is required for node-drain/scale operations. Per the
#    same reasoning nomad-sentinel now uses (Workload Identity, not a
#    static token), this uses identity { env = true } instead — but
#    the actual Nomad ACL *policy* granting that identity the right
#    permissions (node write, for drains) doesn't exist in
#    modules/nomad/ yet, matching nomad_acl_policy.nomad_sentinel's
#    shape but scoped to node operations instead of namespace-wide
#    read/write.

job "nomad-autoscaler" {
  datacenters = ["#{Datacenter}"]
  namespace   = "#{DeploymentNamespace}"
  type        = "service"

  update {
    max_parallel     = 1
    min_healthy_time = "10s"
    healthy_deadline = "3m"
  }

  group "nomad-autoscaler" {
    count = #{ReplicaCount}

    constraint {
      attribute = "${meta.node_pool_type}"
      operator  = "="
      value     = "on-demand"
    }

    network {
      port "http" {
        to = 8080
      }
    }

    task "nomad-autoscaler" {
      driver = "docker"

      config {
        image   = "#{ArtifactRegistry}/nomad-autoscaler:#{ImageTag}"
        ports   = ["http"]
        args    = ["agent", "-config", "/local/config.hcl"]
      }

      # Workload Identity, not a static Nomad ACL token — consistent
      # with nomad-sentinel.nomad.hcl. Whatever this identity is bound
      # to in Nomad's own ACL system (not yet defined) needs at least
      # node write access for drain-before-scale-in.
      identity {
        env = true
      }

      # GCE credentials for the gce-mig target plugin specifically —
      # this is a DIFFERENT identity than the Nomad ACL one above; the
      # plugin needs to call the GCP Compute API, not Nomad's own API.
      # File-based per the plugin's own recommendation (never as an
      # env var, which would be visible to every plugin + the agent
      # process, not just this one).
      vault {
        role = "nomad-autoscaler"
      }

      template {
        data = <<EOF
{{ with secret "gcp/roleset/nomad-autoscaler-#{Environment}/key" }}
{{ .Data.private_key_data | base64Decode }}
{{ end }}
EOF
        destination = "secrets/gce-creds.json"
      }

      template {
        data = <<EOF
http {
  bind_address = "0.0.0.0"
  bind_port    = 8080
}

nomad {
  address = "http://localhost:4646"
}

apm "prometheus" {
  driver = "prometheus"
  config = {
    address = "http://{{ env "NOMAD_UPSTREAM_ADDR_prometheus" }}"
  }
}

target "gce-mig" {
  driver = "gce-mig"
}

strategy "target-value" {
  driver = "target-value"
}
EOF
        destination = "local/config.hcl"
      }

      # Cluster-scaling policies — one per MIG this environment owns.
      # These aren't read from any job's own scaling {} block (unlike
      # frontend's task-scaling policy); they're standalone policy
      # files the Autoscaler agent reads directly.
      template {
        data = <<EOF
scaling "cluster_policy_ondemand" {
  enabled = true
  min     = 1
  max     = 10

  policy {
    cooldown            = "10m"
    evaluation_interval  = "1m"

    check "blocked_evaluations" {
      source = "prometheus"
      query  = "sum(nomad_nomad_blocked_evals_total_blocked)"

      strategy "target-value" {
        target = 0
      }
    }

    target "gce-mig" {
      project  = "#{GcpProject}"
      zone     = "#{GcpZone}"
      mig_name = "#{OndemandMigName}"
    }
  }
}

scaling "cluster_policy_spot" {
  enabled = true
  min     = 0
  max     = 10

  policy {
    cooldown            = "10m"
    evaluation_interval  = "1m"

    check "blocked_evaluations" {
      source = "prometheus"
      query  = "sum(nomad_nomad_blocked_evals_total_blocked)"

      strategy "target-value" {
        target = 0
      }
    }

    target "gce-mig" {
      project  = "#{GcpProject}"
      zone     = "#{GcpZone}"
      mig_name = "#{SpotMigName}"
    }
  }
}
EOF
        destination = "local/policies.hcl"
      }

      resources {
        cpu    = #{Cpu}
        memory = #{Memory}
      }
    }
  }
}
