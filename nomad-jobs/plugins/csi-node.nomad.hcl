variable "environment" {
  type    = string
  default = "dev"
}

locals {
  datacenter = "dc-${var.environment}"
}

job "csi-node" {
  datacenters = [local.datacenter]
  namespace   = "plugins"
  type        = "system"

  update {
    max_parallel      = 1
    min_healthy_time = "10s"
    healthy_deadline = "3m"
  }

  group "csi-node" {
    # Technically redundant for a system job (Nomad already places at
    # most one allocation per node), but the Nomad docs' own
    # plugin-efs example includes this on the node plugin too —
    # matching that rather than assuming it's unnecessary here.
    constraint {
      operator = "distinct_hosts"
      value    = true
    }

    task "csi-node" {
      driver = "docker"

      config {
        image      = "us-central1-docker.pkg.dev/my-project/artifact-registry/gcp-compute-persistent-disk-csi-driver:v1.13.0"
        privileged = true
        args = [
          "--endpoint=unix://csi/csi.sock",
          "--run-controller-service=false",
          "--run-node-service=true",
        ]
        volumes = [
          "/dev:/dev",
        ]
      }

      csi_plugin {
        id        = "gce-pd"
        type      = "node"
        mount_dir = "/csi"
      }

      resources {
        cpu    = 200
        memory = 256
      }
    }
  }
}