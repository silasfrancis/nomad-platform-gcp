# nomad-jobs/plugins/csi-node.nomad.hcl
#
# Node half of the same driver — runs on every client node (system
# job, both on-demand and Spot pools; any node might need to mount a
# volume), handles the actual NodeStageVolume/NodePublishVolume calls
# locally. --run-controller-service=false disables the controller-side
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

job "csi-node" {
  datacenters = ["#{Datacenter}"]
  namespace   = "#{DeploymentNamespace}"
  type        = "system"

  update {
    max_parallel     = 1
    min_healthy_time = "10s"
    healthy_deadline = "3m"
  }

  group "csi-node" {
    task "csi-node" {
      driver = "docker"

      config {
        image      = "#{ArtifactRegistry}/gcp-compute-persistent-disk-csi-driver:#{ImageTag}"
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
        cpu    = #{Cpu}
        memory = #{Memory}
      }
    }
  }
}
