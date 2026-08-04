id        = "prometheus-data-prod"
name      = "prometheus-data-prod"
type      = "csi"
plugin_id = "gce-pd"

capacity_min = "20GiB"
capacity_max = "200GiB"

capability {
  access_mode     = "single-node-writer"
  attachment_mode = "file-system"
}

parameters {
  type = "pd-ssd"
}
