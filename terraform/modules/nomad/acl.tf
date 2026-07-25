# nomad-sentinel — Read Allocations/Jobs Cluster-Wide, Write In Its Own
# Namespace For Remediation Actions.
#
# NOTE: kept as a static ACL token for now, as an interim/fallback —
# whether Nomad's own API supports task-side Workload Identity auth
# the same confirmed way Vault/Consul do hasn't been independently
# verified this session (see modules/vault/secrets.tf's note — Vault
# no longer relays this token, it's dropped from ai_agent_config
# entirely). If WI-based Nomad API auth is confirmed to work once
# nomad-jobs/ is written, this policy/token pair can likely be dropped
# the same way the Consul sidecar tokens were.
resource "nomad_acl_policy" "nomad_sentinel" {
  name        = "nomad-sentinel-${var.environment}"
  description = "AI monitoring agent — ${var.environment}"
  rules_hcl   = <<-EOT
    namespace "monitoring" {
      policy = "write"
    }
    node {
      policy = "read"
    }
  EOT
}

resource "nomad_acl_token" "nomad_sentinel" {
  name     = "nomad-sentinel-${var.environment}"
  type     = "client"
  policies = [nomad_acl_policy.nomad_sentinel.name]
}

# Octopus Deploy — Submit/Plan/Promote Jobs In default Namespace.
# Kept as Terraform-managed (not hand-seeded) per this session's
# decision, so the policy stays visible/referenceable as code. This is
# the one deliberate cross-module ordering dependency in the whole
# system: mgmt/'s Octopus module can't complete its first apply of the
# NomadToken variable until this environment's module has run once.
resource "nomad_acl_policy" "octopus_deploy" {
  name        = "octopus-deploy-${var.environment}"
  description = "Octopus Deploy — ${var.environment}"
  rules_hcl   = <<-EOT
    namespace "default" {
      policy = "write"
    }
  EOT
}

resource "nomad_acl_token" "octopus_deploy" {
  name     = "octopus-deploy-${var.environment}"
  type     = "client"
  policies = [nomad_acl_policy.octopus_deploy.name]
}

# NOTE — github-runner: no policy/token here. Per the documented CI/CD
# flow, the runner never calls Nomad's API directly — it triggers
# Octopus (octo create-release), and Octopus is what calls Nomad.
