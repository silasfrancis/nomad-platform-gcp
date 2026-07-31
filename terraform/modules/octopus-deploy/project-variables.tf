# Project-Scoped Variables
#
# Namespace and replica count are properties of the SERVICE, not the
# environment — cartservice deploys into "boutique" whether it's dev or
# prod, so these are set once per project rather than duplicated per
# environment the way NomadApiUrl/NomadAclToken need to be.
#
# ReplicaCount defaults to 1 for every project — a placeholder until
# actual per-service scaling requirements are decided when nomad-jobs/
# is written. Override per project below if a specific service needs a
# different starting value.
locals {
  replica_count_overrides = {
    frontend = 2
  }
}

resource "octopusdeploy_variable" "deployment_namespace" {
  for_each = local.projects
  owner_id = octopusdeploy_project.this[each.key].id
  name     = "DeploymentNamespace"
  type     = "String"
  value    = each.value.namespace
}

resource "octopusdeploy_variable" "replica_count" {
  for_each = local.projects
  owner_id = octopusdeploy_project.this[each.key].id
  name     = "ReplicaCount"
  type     = "String"
  value    = tostring(lookup(local.replica_count_overrides, each.key, 1))
}


resource "octopusdeploy_variable" "cpu" {
  for_each = local.projects
  owner_id = octopusdeploy_project.this[each.key].id
  name     = "Cpu"
  type     = "String"
  value    = tostring(lookup(local.cpu_overrides, each.key, 200))
}

resource "octopusdeploy_variable" "memory" {
  for_each = local.projects
  owner_id = octopusdeploy_project.this[each.key].id
  name     = "Memory"
  type     = "String"
  value    = tostring(lookup(local.memory_overrides, each.key, 256))
}

# --- Scoped to one project only ---

resource "octopusdeploy_variable" "public_hostname" {
  for_each = toset(["dev", "prod"])
  owner_id = octopusdeploy_project.this["frontend"].id
  name     = "PublicHostname"
  type     = "String"
  value    = each.key == "prod" ? "boutique.lefrancis.org" : "dev.boutique.lefrancis.org"
  scope {
    environments = [local.env_by_key[each.key]]
  }
}

resource "octopusdeploy_variable" "remediation_mode" {
  for_each = toset(["dev", "prod"])
  owner_id = octopusdeploy_project.this["nomad-sentinel"].id
  name     = "RemediationMode"
  type     = "String"
  value    = each.key == "prod" ? "propose" : "execute"
  scope {
    environments = [local.env_by_key[each.key]]
  }
}

locals {
  # cpu is in MHz (Nomad's own unit, not cores) — 200/256 (falls
  # through when a project isn't listed below) is a workable floor for
  # a low-traffic gRPC service doing almost nothing. Everything below
  # is a deviation from that floor, with a reason, not a guess dressed
  # up as a number.
  cpu_overrides = {
    # Direct customer path — canaried, and doing real work per
    # request (rendering, orchestrating 6 downstream calls).
    frontend        = 300
    cartservice     = 300
    checkoutservice = 300

    # JVM — adservice needs meaningfully more headroom than every
    # other boutique service just to cover heap + JIT overhead, not
    # because it does more work than, say, shippingservice.
    adservice = 300

    # Real workloads with actual throughput requirements, not
    # thin API wrappers.
    postgres   = 300
    prometheus = 300
    loki       = 300

    # Genuinely lighter than the 200 floor — flags/CLI wrappers with
    # near-zero logic of their own.
    alloy           = 100
    node-exporter   = 50
    falco-webhook   = 100
    consul-snapshot = 100
  }

  memory_overrides = {
    frontend        = 384
    cartservice     = 384 # .NET runtime overhead on top of the app itself
    adservice       = 512 # JVM heap — this is the one that actually matters; Java needs meaningfully more than every Go/Node/Python service here

    postgres   = 512
    prometheus = 512 # TSDB in memory — grows with retention/cardinality
    loki       = 512

    # Interpreted-language baseline (Python/Node) runs a bit heavier
    # than a compiled Go binary at the same workload — not because
    # these do more, just what the runtime itself costs.
    paymentservice         = 300
    currencyservice        = 300
    emailservice            = 300
    recommendationservice  = 300
    loadgenerator           = 300

    # Compiled, minimal logic — leaner than the 256 default, not just
    # left at it by omission.
    shippingservice = 128

    alloy           = 128
    node-exporter   = 64
    falco-webhook   = 128
    consul-snapshot = 128
  }
}