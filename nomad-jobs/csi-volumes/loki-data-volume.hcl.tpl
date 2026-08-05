# nomad-jobs/csi-volumes/loki-data-volume.hcl.tpl
#
# Same mechanism as postgres-data-volume.hcl.tpl. id matches
# loki.nomad.hcl's volume.source after substitution.

id           = "loki-data-$ENVIRONMENT"
name         = "loki-data-$ENVIRONMENT"
type         = "csi"
plugin_id    = "gce-pd"
capacity_min = "$MIN_CAPACITY"
capacity_max = "$MAX_CAPACITY"

capability {
  access_mode     = "single-node-writer"
  attachment_mode = "file-system"
}

parameters {
  type = "$DISK_TYPE"
}
