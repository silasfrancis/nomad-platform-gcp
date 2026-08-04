# nomad-jobs/datastore/postgres-data-volume-prod.hcl
#
# Sibling of postgres-data-volume-dev.hcl — see that file for the full
# explanation of what this is and how id/plugin_id link everything
# together. Only real difference: a higher capacity ceiling for prod.

id        = "postgres-data-prod"
name      = "postgres-data-prod"
type      = "csi"
plugin_id = "gce-pd"

capacity_min = "20GiB"
capacity_max = "100GiB"

capability {
  access_mode     = "single-node-writer"
  attachment_mode = "file-system"
}

parameters {
  type = "pd-ssd"
}
