# Platform Namespaces
#
# Grouped by operational concern rather than by team or service — each
# namespace is a blast-radius boundary for who can stop, restart, or
# read logs for what's inside it, independent of any data-level access
# controls Vault/Consul already provide.
#
# Quotas are a Nomad Enterprise-only feature (nomad_quota_specification
# has no effect on Nomad OSS) — omitted here rather than added as
# dead configuration. Revisit if/when running Nomad Enterprise.

resource "nomad_namespace" "boutique" {
  name        = "boutique"
  description = "Customer-facing application workloads"
}

resource "nomad_namespace" "monitoring" {
  name        = "monitoring"
  description = "Observability stack: the AI monitoring agent, the metrics API, Prometheus, and related monitoring services."
}

resource "nomad_namespace" "datastore" {
  name        = "datastore"
  description = "Stateful database workloads, such as PostgreSQL and Redis, kept isolated from application and tooling namespaces."
}

resource "nomad_namespace" "security" {
  name        = "security"
  description = "Security tooling, including the runtime security webhook receiver."
}

resource "nomad_namespace" "operations" {
  name        = "operations"
  description = "Scheduled periodic backup jobs and other operations tasks."
}

resource "nomad_namespace" "plugins" {
  name        = "plugins"
  description = "CSI driver and autoscaler plugin jobs"
}
