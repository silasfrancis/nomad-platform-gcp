# nomad-jobs/csi-volumes/prometheus-data-volume.hcl.tpl
#
# Same mechanism as postgres-data-volume.hcl.tpl — see that file for
# the full explanation. id matches prometheus.nomad.hcl's volume.source
# after substitution.

id           = "prometheus-data-$ENVIRONMENT"
name         = "prometheus-data-$ENVIRONMENT"
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
