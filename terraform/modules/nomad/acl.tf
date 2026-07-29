# nomad-sentinel — Read Allocations/Jobs Cluster-Wide, Write In Its Own
# Namespace For Remediation Actions
#
# Needs namespace "*" rather than a single namespace: the agent polls
# allocations across the entire cluster to detect anomalies anywhere,
# not just within its own namespace.
resource "nomad_acl_policy" "nomad_sentinel" {
  name        = "nomad-sentinel-${var.environment}"
  description = "AI monitoring agent — read/write across all namespaces to detect and remediate anomalies cluster-wide."
  rules_hcl   = <<-EOT
    namespace "*" {
      policy = "write"
    }
    node {
      policy = "read"
    }
  EOT
  job_acl {
    namespace = "monitoring"
    job_id    = "nomad-sentinel"
  }
}

# No nomad_acl_token is created for nomad-sentinel. The platform uses
# Nomad Workload Identity by default: the job authenticates using its
# own signed identity (`identity { env = true }` in the job spec),
# which Nomad resolves against the policy above with no standing
# credential ever minted or stored.
#
# Uncomment the block below ONLY if a specific workload cannot use
# Workload Identity and a static token is genuinely required instead.
#
# resource "nomad_acl_token" "nomad_sentinel" {
#   name     = "nomad-sentinel-${var.environment}"
#   type     = "client"
#   policies = [nomad_acl_policy.nomad_sentinel.name]
# }

# Octopus Deploy — Submits, Plans, And Promotes Releases
#
# Scoped to the namespaces Octopus actually deploys projects into per
# the current project list (application workloads and the monitoring
# stack). Database and security namespaces are deliberately excluded —
# nothing in the current set of Octopus projects deploys into them.
# Revisit if a future project needs Octopus to manage PostgreSQL or the
# security tooling directly.
resource "nomad_acl_policy" "octopus_deploy" {
  name        = "octopus-deploy-${var.environment}"
  description = "Octopus Deploy — submit, plan, and promote releases into the boutique and monitoring namespaces."
  rules_hcl   = <<-EOT
    namespace "boutique" {
      policy = "write"
    }
    namespace "monitoring" {
      policy = "write"
    }
  EOT
}

resource "nomad_acl_token" "octopus_deploy" {
  name     = "octopus-deploy-${var.environment}"
  type     = "client"
  policies = [nomad_acl_policy.octopus_deploy.name]
}

# github-runner has no policy or token here. The CI runner never calls
# Nomad's API directly — it triggers a release in Octopus, and Octopus
# is what calls Nomad.
