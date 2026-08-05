# nomad-jobs/plugins/csi-node.nomad.hcl
#
# Same deployment reasoning as csi-controller.nomad.hcl — not Octopus,
# real Nomad variables instead of #{} tokens.
#
# Node half of the same driver — runs on every client node (system
# job, both on-demand and Spot pools; any node might need to mount a
# volume). --run-controller-service=false disables the controller-side
# gRPC service here, mirroring csi-controller.nomad.hcl's split the
# other way.
#
# Needs privileged + host /dev access to actually attach/mount block
# devices — this is real elevated access, not boilerplate, and is
# specific to the node plugin; csi-controller.nomad.hcl needs neither.
#
# Same id ("gce-pd") as csi-controller.nomad.hcl — a CSI volume's
# plugin_id must match on both the controller and node plugin for
# Nomad to treat them as the same driver.

variable "environment" {
  type    = string
  default = "dev"
}

variable "artifact_registry" {
  type = string
}

variable "image_tag" {
  type = string
}

locals {
  datacenter = "dc-${var.environment}"
}

job "csi-node" {
  datacenters = [local.datacenter]
  namespace   = "plugins"
  type        = "system"

  update {
    max_parallel     = 1
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
        image      = "${var.artifact_registry}/gcp-compute-persistent-disk-csi-driver:${var.image_tag}"
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
