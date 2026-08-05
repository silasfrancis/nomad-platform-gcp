# nomad-jobs/csi-volumes/postgres-data-volume.hcl.tpl
#
# NOT valid HCL on its own — $ENVIRONMENT/$MIN_CAPACITY/$MAX_CAPACITY/
# $DISK_TYPE get substituted by apply.sh (via envsubst) before this
# ever reaches `nomad volume create`. Same architecture Octopus uses
# for job specs' #{} tokens, just one layer earlier and much simpler,
# since this never goes through Octopus at all — see apply.sh.
#
# id must exactly match whatever the consuming job's volume.source
# resolves to (postgres.nomad.hcl's "postgres-data-#{Environment}").
# plugin_id must match plugins/csi-controller.nomad.hcl /
# csi-node.nomad.hcl's own id ("gce-pd").

id           = "postgres-data-$ENVIRONMENT"
name         = "postgres-data-$ENVIRONMENT"
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

mount_options {
  fs_type     = "ext4"
  mount_flags = ["noatime"]
}