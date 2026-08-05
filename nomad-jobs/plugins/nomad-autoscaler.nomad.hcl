# nomad-jobs/plugins/nomad-autoscaler.nomad.hcl
#
# Same deployment reasoning as csi-controller.nomad.hcl — not Octopus,
# real Nomad variables instead of #{} tokens.
#
# One instance per environment (deploy.sh's -var=environment picks
# which) — manages both scaling mechanisms documented in the
# architecture doc 2.5:
#
# Task scaling (frontend's HPA-equivalent): needs NO configuration
# here at all. The Autoscaler discovers frontend's own scaling {}
# block via the Nomad API automatically; the agent config below only
# needs to know Prometheus exists as an APM source — reached via plain
# Consul DNS (prometheus.service.consul:9090), NOT a Connect upstream.
# An earlier version of this file referenced NOMAD_UPSTREAM_ADDR_prometheus,
# which never existed: this job has no sidecar, and Prometheus itself
# is deliberately unmeshed (see prometheus.nomad.hcl), so there was
# never an upstream to reference in the first place. Fixed here.
#
# Cluster scaling (MIG resize): needs one policy per MIG, hardcoded
# into the agent config's own scaling blocks (not derived from
# anything in a job spec) — this environment's own 2 (ondemand + spot).
# var.gcp_zone/ondemand_mig_name/spot_mig_name have no defaults,
# deliberately — literal GCE resource names with no reasonable
# universal default, unlike environment.
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
#    same Workload Identity reasoning nomad-sentinel now uses, this
#    uses identity { env = true } instead of a static token — but the
#    actual Nomad ACL *policy* granting that identity the right
#    permissions (node write, for drains) doesn't exist in
#    modules/nomad/ yet, matching nomad_acl_policy.nomad_sentinel's
#    shape but scoped to node operations instead of namespace-wide
#    read/write.

variable "environment" {
  type    = string
  default = "dev"
}

variable "gcp_project" {
  type = string
}

variable "artifact_registry" {
  type = string
}

variable "image_tag" {
  type = string
}

variable "gcp_zone" {
  type = string
}

variable "ondemand_mig_name" {
  type = string
}

variable "spot_mig_name" {
  type = string
}

locals {
  datacenter = "dc-${var.environment}"
}

job "nomad-autoscaler" {
  datacenters = [local.datacenter]
  namespace   = "plugins"
  type        = "service"

  update {
    max_parallel     = 1
    min_healthy_time = "10s"
    healthy_deadline = "3m"
  }

  group "nomad-autoscaler" {
    count = 1

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
        image = "${var.artifact_registry}/nomad-autoscaler:${var.image_tag}"
        ports = ["http"]
        args  = ["agent", "-config", "/local/config.hcl"]
      }

      # Workload Identity, not a static Nomad ACL token — consistent
      # with nomad-sentinel.nomad.hcl. Whatever this identity is bound
      # to in Nomad's own ACL system (not yet defined) needs at least
      # node write access for drain-before-scale-in.
      identity {
        env = true
      }

      # GCE credentials for the gce-mig target plugin specifically —
      # a DIFFERENT identity than the Nomad ACL one above; the plugin
      # needs to call the GCP Compute API, not Nomad's own API.
      # File-based per the plugin's own recommendation (never as an
      # env var, which would be visible to every plugin + the agent
      # process, not just this one).
      vault {
        role = "nomad-autoscaler"
      }

      template {
        data = <<EOF
{{ with secret "gcp/roleset/nomad-autoscaler-${var.environment}/key" }}
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
    address = "http://prometheus.service.consul:9090"
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
      project  = "${var.gcp_project}"
      zone     = "${var.gcp_zone}"
      mig_name = "${var.ondemand_mig_name}"
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
      project  = "${var.gcp_project}"
      zone     = "${var.gcp_zone}"
      mig_name = "${var.spot_mig_name}"
    }
  }
}
EOF
        destination = "local/policies.hcl"
      }

      resources {
        cpu    = 200
        memory = 256
      }
    }
  }
}
