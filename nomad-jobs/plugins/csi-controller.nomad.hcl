# nomad-jobs/plugins/csi-controller.nomad.hcl
#
# NOT deployed via Octopus — plugins change rarely enough that a
# manual, deliberate `nomad job run` (via deploy.sh, IAP-tunneled)
# beats wiring up a full CI pipeline for something this infrequent.
# Real Nomad variable blocks instead of #{} Octopus tokens — one file
# covers both environments via -var overrides at apply time, same
# mental model as Terraform.
#
# GCE Persistent Disk CSI driver, controller half — talks to the GCE
# API for CreateVolume/DeleteVolume/ControllerPublish, doesn't need to
# run on every node the way the node plugin does. --run-node-service=false
# disables the node-side gRPC service on this instance.
#
# Mirrors upstream kubernetes-sigs/gcp-compute-persistent-disk-csi-driver
# into artifact_registry rather than pulling registry.k8s.io directly —
# same "no images pulled from an external registry" policy the
# architecture doc already states for Online Boutique (5.1).
#
# NOT YET VERIFIED: the GCE service account this runs under needs
# compute.instances.get/attachDisk/detachDisk plus roles/compute.storageAdmin
# and roles/iam.serviceAccountUser, per the driver's own install docs —
# not yet added to the Nomad client service accounts.

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
        image = "us-central1-docker.pkg.dev/my-project/artifact-registry/gcp-compute-persistent-disk-csi-driver:v1.13.0"
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