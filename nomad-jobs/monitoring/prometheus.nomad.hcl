# nomad-jobs/monitoring/prometheus.nomad.hcl
#
# One instance per environment (this same job spec promoted dev ->
# prod, scraping only its own cluster — dev and prod are never
# federated). Config is baked into its own image (monitoring/prometheus/
# source directory, own Dockerfile wrapping the upstream prom/prometheus
# image + a prometheus.yml) — same pattern as alloy.nomad.hcl and every
# application service, not templated at deploy time.
#
# Deliberately not Connect-meshed: Prometheus scrapes every target's
# real port directly (what pull-based scraping requires), it isn't
# making the kind of app-to-app call Connect upstreams are for.
#
# NOT YET COMPLETE: Vault is a documented scrape target (architecture
# doc 8.2) but lives on mgmt-vm, outside this cluster entirely, and
# the existing firewall table only opens mgmt -> env (9100/3100/4317),
# not env -> mgmt:8200 the other direction a scrape would need. Left
# out of the baked-in scrape config rather than silently included and
# broken — needs either a firewall addition or dropping Vault from
# this Prometheus's own scrape list.

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

    # CSI, not host — NOT YET COMPLETE, same flag as postgres.nomad.hcl:
    # the GCE PD CSI driver itself isn't deployed anywhere yet, and the
    # Nomad client service accounts don't have the disk-management IAM
    # permissions it needs.
    volume "prometheus-data" {
      type            = "csi"
      source          = "prometheus-data-#{Environment}"
      read_only       = false
      attachment_mode = "file-system"
      access_mode     = "single-node-writer"
    }

    network {
      port "http" {
        to = 9090
      }
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

    task "prometheus" {
      driver = "docker"

      config {
        image = "#{ArtifactRegistry}/prometheus:#{ImageTag}"
        ports = ["http"]
      }

      volume_mount {
        volume      = "prometheus-data"
        destination = "/prometheus"
      }

      resources {
        cpu    = #{Cpu}
        memory = #{Memory}
      }
    }
  }
}
