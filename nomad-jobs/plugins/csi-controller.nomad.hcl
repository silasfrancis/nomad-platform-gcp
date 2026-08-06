variable "environment" {
  type    = string
  default = "dev"
}

locals {
  datacenter = "dc-${var.environment}"
}

job "csi-controller" {
  datacenters = [local.datacenter]
  namespace   = "plugins"
  type        = "service"

  update {
    max_parallel      = 1
    min_healthy_time = "10s"
    healthy_deadline = "3m"
  }

  group "csi-controller" {
    count = 1

    constraint {
      attribute = "${meta.node_pool_type}"
      operator  = "="
      value     = "on-demand"
    }

    # Distributes replicas across nodes if count is ever bumped above
    # 1 — per the Nomad docs' own recommendation for CSI controller
    # plugins specifically.
    constraint {
      operator = "distinct_hosts"
      value    = true
    }

    task "csi-controller" {
      driver = "docker"

      config {
        image = "registry.k8s.io/cloud-provider-gcp/gcp-compute-persistent-disk-csi-driver:v1.20.0"
        args = [
          "--endpoint=unix://csi/csi.sock",
          "--run-controller-service=true",
          "--run-node-service=false",
        ]
      }

      # This id ("gce-pd") is the one thing every volume spec in
      # csi-volumes/ must reference exactly in its own plugin_id field.
      csi_plugin {
        id        = "gce-pd"
        type      = "controller"
        mount_dir = "/csi"
      }

      resources {
        cpu    = 200
        memory = 256
      }
    }
  }
}