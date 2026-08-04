# nomad-jobs/plugins/csi-controller.nomad.hcl
#
# GCE Persistent Disk CSI driver, controller half — talks to the GCE
# API for CreateVolume/DeleteVolume/ControllerPublish, doesn't need to
# run on every node the way the node plugin does. --run-node-service=false
# disables the node-side gRPC service on this instance, per the
# driver's own two flags (both default true if unset — confirmed
# against the driver's own docs).
#
# Mirrors upstream kubernetes-sigs/gcp-compute-persistent-disk-csi-driver
# into #{ArtifactRegistry} rather than pulling registry.k8s.io directly —
# same "no images pulled from an external registry" policy the
# architecture doc already states for Online Boutique (5.1). This is a
# different CI shape than every other image in this project, though:
# a mirror/retag pipeline, not a build-from-source one — worth keeping
# distinct when CI/CD gets built.
#
# NOT YET VERIFIED: the GCE service account this runs under needs
# compute.instances.get/attachDisk/detachDisk plus roles/compute.storageAdmin
# and roles/iam.serviceAccountUser, per the driver's own install docs —
# not yet added to the Nomad client service accounts.

job "csi-controller" {
  datacenters = ["#{Datacenter}"]
  namespace   = "#{DeploymentNamespace}"
  type        = "service"

  update {
    max_parallel     = 1
    min_healthy_time = "10s"
    healthy_deadline = "3m"
  }

  group "csi-controller" {
    count = #{ReplicaCount}

    constraint {
      attribute = "${meta.node_pool_type}"
      operator  = "="
      value     = "on-demand"
    }

    task "csi-controller" {
      driver = "docker"

      config {
        image = "#{ArtifactRegistry}/gcp-compute-persistent-disk-csi-driver:#{ImageTag}"
        args = [
          "--endpoint=unix://csi/csi.sock",
          "--run-controller-service=true",
          "--run-node-service=false",
        ]
      }

      # This id ("gce-pd") is the one thing every volume registration
      # in this project must reference exactly — see
      # datastore/postgres-data-volume.hcl,
      # monitoring/prometheus-data-volume.hcl, and
      # monitoring/loki-data-volume.hcl's plugin_id fields, which all
      # point back here.
      csi_plugin {
        id        = "gce-pd"
        type      = "controller"
        mount_dir = "/csi"
      }

      resources {
        cpu    = #{Cpu}
        memory = #{Memory}
      }
    }
  }
}
