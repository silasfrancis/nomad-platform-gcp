# nomad-sentinel — Read Allocations/Jobs Cluster-Wide, Write In Its Own
# Namespace For Remediation Actions (restart/revert/increase_memory)
resource "nomad_acl_policy" "nomad_sentinel_dev" {
  provider    = nomad.dev
  name        = "nomad-sentinel-dev"
  description = "AI monitoring agent — dev"
  rules_hcl   = <<-EOT
    namespace "monitoring" {
      policy = "write"
    }
    node {
      policy = "read"
    }
  EOT
}

resource "nomad_acl_token" "nomad_sentinel_dev" {
  provider = nomad.dev
  name     = "nomad-sentinel-dev"
  type     = "client"
  policies = [nomad_acl_policy.nomad_sentinel_dev.name]
}

resource "nomad_acl_policy" "nomad_sentinel_prod" {
  provider    = nomad.prod
  name        = "nomad-sentinel-prod"
  description = "AI monitoring agent — prod"
  rules_hcl   = <<-EOT
    namespace "monitoring" {
      policy = "write"
    }
    node {
      policy = "read"
    }
  EOT
}

resource "nomad_acl_token" "nomad_sentinel_prod" {
  provider = nomad.prod
  name     = "nomad-sentinel-prod"
  type     = "client"
  policies = [nomad_acl_policy.nomad_sentinel_prod.name]
}

# Octopus Deploy — Submit/Plan/Promote Jobs In default Namespace
resource "nomad_acl_policy" "octopus_dev" {
  provider    = nomad.dev
  name        = "octopus-deploy-dev"
  description = "Octopus Deploy — dev"
  rules_hcl   = <<-EOT
    namespace "default" {
      policy = "write"
    }
  EOT
}

resource "nomad_acl_token" "octopus_dev" {
  provider = nomad.dev
  name     = "octopus-deploy-dev"
  type     = "client"
  policies = [nomad_acl_policy.octopus_dev.name]
}

resource "nomad_acl_policy" "octopus_prod" {
  provider    = nomad.prod
  name        = "octopus-deploy-prod"
  description = "Octopus Deploy — prod"
  rules_hcl   = <<-EOT
    namespace "default" {
      policy = "write"
    }
  EOT
}

resource "nomad_acl_token" "octopus_prod" {
  provider = nomad.prod
  name     = "octopus-deploy-prod"
  type     = "client"
  policies = [nomad_acl_policy.octopus_prod.name]
}

# NOTE — github-runner: no policy/token here. Per the documented CI/CD
# flow, the runner never calls Nomad's API directly — it triggers
# Octopus (octo create-release), and Octopus is what calls Nomad.
# Reconsider only if a post-deploy verification step gets added later
# that isn't in the architecture doc today.
