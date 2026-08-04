# nomad-jobs/datastore/postgres-data-volume-dev.hcl
#
# NOT a job spec — this is a Nomad CSI volume registration, applied
# with `nomad volume register`, not `nomad job run`/Octopus. It's a
# one-time (or rarely-repeated) operation, likely something Ansible or
# a setup script runs once per environment before postgres.nomad.hcl
# is ever deployed — outside the CI/CD pipeline entirely.
#
# id here MUST exactly match postgres.nomad.hcl's volume.source field
# after Octopus substitutes #{Environment} — "postgres-data-dev" for
# this file, "postgres-data-prod" for the sibling one. That's the
# actual link between "which volume a job asks to mount" and "which
# registered volume answers that request". plugin_id must match
# csi-controller.nomad.hcl/csi-node.nomad.hcl's own id ("gce-pd") —
# the separate link between "which volume" and "which driver manages
# it".

id        = "postgres-data-dev"
name      = "postgres-data-dev"
type      = "csi"
plugin_id = "gce-pd"

capacity_min = "20GiB"
capacity_max = "50GiB"

capability {
  access_mode     = "single-node-writer"
  attachment_mode = "file-system"
}

# NOT YET VERIFIED: exact parameter keys the GCE PD CSI driver expects
# here (disk type, zone) haven't been checked against its current
# StorageClass/parameters reference — confirm before registering.
parameters {
  type = "pd-ssd"
}
