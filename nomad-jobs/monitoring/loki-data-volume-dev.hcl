# nomad-jobs/monitoring/loki-data-volume-dev.hcl
#
# Same mechanism as datastore/postgres-data-volume-dev.hcl. id matches
# loki.nomad.hcl's volume.source after substitution; plugin_id matches
# plugins/csi-controller.nomad.hcl / csi-node.nomad.hcl's own id.

id        = "loki-data-dev"
name      = "loki-data-dev"
type      = "csi"
plugin_id = "gce-pd"

capacity_min = "20GiB"
capacity_max = "100GiB"

capability {
  access_mode     = "single-node-writer"
  attachment_mode = "file-system"
}

parameters {
  type = "pd-standard"
}
