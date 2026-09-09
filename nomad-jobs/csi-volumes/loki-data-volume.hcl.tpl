# loki-data-volume.hcl.tpl
#
# id must exactly match whatever the consuming job's volume.source
# resolves to (loki.nomad.hcl's "loki-data-#{Environment}").
# plugin_id must match plugins/csi-controller.nomad.hcl /
# csi-node.nomad.hcl's own id ("gce-pd").

id           = "loki-data-$ENVIRONMENT"
name         = "loki-data-$ENVIRONMENT"
type         = "csi"
plugin_id    = "gce-pd"
namespace    = "$NAMESPACE"
capacity_min = "$MIN_CAPACITY"
capacity_max = "$MAX_CAPACITY"

capability {
  access_mode     = "single-node-writer"
  attachment_mode = "file-system"
}

topology_request {
  preferred {
    topology {
      segments {
        "topology.gke.io/zone" = "$ZONE_1"
      }
      segments {
        "topology.gke.io/zone" = "$ZONE_2"
      }
      segments {
        "topology.gke.io/zone" = "$ZONE_3"
      }
    }
  }
}

parameters {
  type = "$DISK_TYPE"
}

mount_options {
  fs_type     = "ext4"
  mount_flags = ["noatime"]
}