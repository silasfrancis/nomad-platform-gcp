#!/bin/bash
# nomad-jobs/csi-volumes/apply.sh
#
# Renders each *.hcl.tpl template with envsubst (substituting the
# $VAR placeholders for one environment) and creates the result with
# `nomad volume create`. Not deployed via Octopus — same reasoning as
# plugins/deploy.sh. Run after IAP-tunneling to the target cluster
# (see platform-config's scripts/open-tunnel.sh dev|prod).
#
# Per-volume capacity/disk-type defaults are set here per environment
# rather than passed on the command line — export any of MIN_CAPACITY/
# MAX_CAPACITY/DISK_TYPE yourself before running if a one-off value is
# needed instead.
#
# Requires envsubst (GNU gettext) — check it's on PATH before running;
# on Debian/Ubuntu (including WSL2) it's `apt install gettext-base` if
# missing.
#
# Usage: ./apply.sh <dev|prod>

set -euo pipefail
ENVIRONMENT="${1:?Usage: ./apply.sh <dev|prod>}"

if [[ "${ENVIRONMENT}" != "dev" && "${ENVIRONMENT}" != "prod" ]]; then
  echo "ERROR: environment must be 'dev' or 'prod', got '${ENVIRONMENT}'" >&2
  exit 1
fi

if ! command -v envsubst &> /dev/null; then
  echo "ERROR: envsubst not found — install gettext-base (apt install gettext-base)" >&2
  exit 1
fi

export ENVIRONMENT

render_and_create() {
  local template="$1"
  local rendered
  rendered="$(mktemp)"
  envsubst < "${template}" > "${rendered}"
  echo "--- ${template} -> ${rendered} ---"
  cat "${rendered}"
  echo "---"
  nomad volume create "${rendered}"
  rm -f "${rendered}"
}

if [[ "${ENVIRONMENT}" == "prod" ]]; then
  export MIN_CAPACITY="20GiB" MAX_CAPACITY="100GiB" DISK_TYPE="pd-ssd"
  render_and_create postgres-data-volume.hcl.tpl

  export MIN_CAPACITY="20GiB" MAX_CAPACITY="200GiB" DISK_TYPE="pd-ssd"
  render_and_create prometheus-data-volume.hcl.tpl

  export MIN_CAPACITY="20GiB" MAX_CAPACITY="200GiB" DISK_TYPE="pd-standard"
  render_and_create loki-data-volume.hcl.tpl
else
  export MIN_CAPACITY="20GiB" MAX_CAPACITY="50GiB" DISK_TYPE="pd-ssd"
  render_and_create postgres-data-volume.hcl.tpl

  export MIN_CAPACITY="20GiB" MAX_CAPACITY="100GiB" DISK_TYPE="pd-ssd"
  render_and_create prometheus-data-volume.hcl.tpl

  export MIN_CAPACITY="20GiB" MAX_CAPACITY="100GiB" DISK_TYPE="pd-standard"
  render_and_create loki-data-volume.hcl.tpl
fi

echo "Done."
