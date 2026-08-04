# nomad-jobs/monitoring/prometheus-data-volume-dev.hcl
#
# Same mechanism as datastore/postgres-data-volume-dev.hcl — see that
# file for the full explanation. id matches prometheus.nomad.hcl's
# volume.source after substitution; plugin_id matches
# plugins/csi-controller.nomad.hcl / csi-node.nomad.hcl's own id.

id        = "prometheus-data-dev"
name      = "prometheus-data-dev"
type      = "csi"
plugin_id = "gce-pd"

capacity_min = "20GiB"
capacity_max = "100GiB" # TSDB grows with retention/cardinality — see cpu_overrides' own comment on this

capability {
  access_mode     = "single-node-writer"
  attachment_mode = "file-system"
}

parameters {
  type = "pd-ssd"
}
