locals {
  namespaces = {
    boutique = {
      description = "Customer-facing application workloads"
    }
    monitoring = {
      description = "Observability stack: the AI monitoring agent, the metrics API, Prometheus, and related monitoring services."
    }
    datastore = {
      description = "Stateful database workloads, such as PostgreSQL and Redis, kept isolated from application and tooling namespaces."
    }
    security = {
      description = "Security tooling, including the runtime security webhook receiver."
    }
    operations = {
      description = "Scheduled periodic backup jobs and other operations tasks."
    }
    plugins = {
      description = "CSI driver and autoscaler plugin jobs"
    }
  }
}