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
  node_pool   = "on-demand"
  type        = "service"

  update {
    max_parallel      = 1
    min_healthy_time = "10s"
    healthy_deadline = "3m"
  }

  group "csi-controller" {
    count = 1

    constraint {
      attribute = "${node.class}"
      operator  = "="
      value     = "critical"
    }

    constraint {
      operator = "distinct_hosts"
      value    = true
    }

    task "csi-controller" {
      driver = "docker"

      config {
        image = "registry.k8s.io/cloud-provider-gcp/gcp-compute-persistent-disk-csi-driver:v1.26.0"
        args = [
          "--endpoint=unix:/csi/csi.sock",
          "--run-controller-service=true",
          "--run-node-service=false",
        ]
      }

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