# nomad-jobs/monitoring/prometheus.nomad.hcl
#
# One instance per environment (this same job spec promoted dev ->
# prod, scraping only its own cluster — dev and prod are never
# federated). Config is templated inline and substituted by Octopus at
# deploy time, not baked into the image or fetched from anywhere
# external — the one exception to this project's usual
# bake-into-image pattern, since scrape targets are the kind of thing
# you want to change without a full image rebuild.
#
# NOT YET COMPLETE: Vault is a documented scrape target (architecture
# doc 8.2) but lives on mgmt-vm, outside this cluster entirely, and
# the existing firewall table only opens mgmt -> env (9100/3100/4317),
# not env -> mgmt:8200 the other direction a scrape would need. Left
# out of the job below rather than silently included and broken —
# needs either a firewall addition or dropping Vault from this
# Prometheus's own scrape list (Grafana could point at Vault's own
# /metrics through a different path instead).

job "prometheus" {
  datacenters = ["#{Datacenter}"]
  namespace   = "#{DeploymentNamespace}"
  type        = "service"

  update {
    max_parallel     = 1
    min_healthy_time = "10s"
    healthy_deadline = "3m"
    auto_revert      = true
  }

  group "prometheus" {
    count = #{ReplicaCount}

    constraint {
      attribute = "${meta.node_pool_type}"
      operator  = "="
      value     = "on-demand"
    }

    volume "prometheus-data" {
      type      = "host"
      source    = "prometheus-data-#{Environment}"
      read_only = false
    }

    network {
      port "http" {
        to = 9090
      }
    }

    task "prometheus" {
      driver = "docker"

      config {
        image   = "prom/prometheus:v2.55.1"
        ports   = ["http"]
        args    = ["--config.file=/local/prometheus.yml", "--storage.tsdb.path=/prometheus"]
        volumes = ["prometheus-data:/prometheus"]
      }

      template {
        data = <<EOF
global:
  scrape_interval: 15s

scrape_configs:
  # Node Exporter, Traefik, and every application service (Online
  # Boutique + metrics-api + nomad-sentinel) are all Consul-registered
  # with health checks — one Consul SD config per role, filtered by
  # tag, rather than a static target list that goes stale the moment
  # a MIG scales.
  - job_name: node-exporter
    consul_sd_configs:
      - server: 'localhost:8500'
        services: ['node-exporter']

  - job_name: traefik
    consul_sd_configs:
      - server: 'localhost:8500'
        services: ['nomad-dev', 'nomad-prod', 'consul-dev', 'consul-prod']

  - job_name: boutique-services
    consul_sd_configs:
      - server: 'localhost:8500'
        tags: ['metrics']

  - job_name: nomad
    static_configs:
      - targets: ['#{Datacenter}-server.service.consul:4646']

  - job_name: consul
    static_configs:
      - targets: ['localhost:8500']
EOF
        destination = "local/prometheus.yml"
      }

      resources {
        cpu    = #{Cpu}
        memory = #{Memory}
      }

      service {
        name = "prometheus"
        port = "http"

        check {
          type     = "http"
          path     = "/-/healthy"
          interval = "10s"
          timeout  = "2s"
        }
      }
    }
  }
}
