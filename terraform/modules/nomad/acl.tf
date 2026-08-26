# Nomad Sentinel: Platform monitoring agent
# Needs namespace "*" as  the agent polls allocations across the entire cluster to detect anomalies anywhere
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
    job_id = "nomad-sentinel"  # workload identity
    namespace = "monitoring"
  }
}

# Nomad Autoscaler 
resource "nomad_acl_policy" "nomad_autoscaler" {
  name        = "nomad-autoscaler-${var.environment}"
  description = "Nomad Autoscaler — write across all namespaces to scale job task groups and node state."
  rules_hcl   = <<-EOT
    namespace "*" {
      policy = "write"
    }
    node {
      policy = "write"
    }
  EOT
  job_acl {
    job_id    = "nomad-autoscaler"   # workload identity
    namespace = "plugins"
  }
}

# No nomad_acl_token is created for nomad-sentinel and nomad autoscaler. The platform uses
# Nomad Workload Identity by default: the job authenticates using its
# own signed identity (`identity { env = true }` in the job spec),
# which Nomad resolves against the policy above with no standing
# credential ever minted or stored.


# Octopus Deploy — Submits, Plans, And Promotes Releases
#
# Scoped to the namespaces Octopus actually deploys projects into 
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
    namespace "security" {
      policy = "write"
    }
    namespace "datastore" {
      policy = "write"
    }
    namespace "operations" {
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
