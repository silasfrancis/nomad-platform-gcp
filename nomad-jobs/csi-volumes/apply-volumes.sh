#!/bin/bash
# 
# Renders each *.hcl.tpl template with envsubst (substituting the
# $VAR placeholders for one environment) and creates the result with
# `nomad volume create. Run after IAP-tunneling to the target cluster
# (see scripts/open-tunnel.sh dev|prod).
#
# Per-volume capacity/disk-type defaults are set here per environment
# rather than passed on the command line — export any of MIN_CAPACITY/
# MAX_CAPACITY/DISK_TYPE yourself before running if a one-off value is
# needed instead.
#
# Requires envsubst (GNU gettext) — check it's on PATH before running;
# on Debian/Ubuntu  it's `apt install gettext-base` if
# missing.
#
# Usage: ./apply-volumes.sh <dev|prod>

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

# Client MIG zones, region-wide — export ZONE_1/ZONE_2/ZONE_3
#  if the deployment targets a different region from the default (europe-west1)

: "${ZONE_1:=europe-west1-b}"
: "${ZONE_2:=europe-west1-c}"
: "${ZONE_3:=europe-west1-d}"
export ZONE_1 ZONE_2 ZONE_3

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
  export MIN_CAPACITY="20GiB" MAX_CAPACITY="100GiB" DISK_TYPE="pd-ssd" NAMESPACE="datastore"
  render_and_create postgres-data-volume.hcl.tpl

  export MIN_CAPACITY="20GiB" MAX_CAPACITY="100GiB" DISK_TYPE="pd-ssd" NAMESPACE="monitoring"
  render_and_create prometheus-data-volume.hcl.tpl

  export MIN_CAPACITY="20GiB" MAX_CAPACITY="100GiB" DISK_TYPE="pd-standard" NAMESPACE="monitoring"
  render_and_create loki-data-volume.hcl.tpl
else
  export MIN_CAPACITY="20GiB" MAX_CAPACITY="50GiB" DISK_TYPE="pd-standard" NAMESPACE="datastore"
  render_and_create postgres-data-volume.hcl.tpl

  export MIN_CAPACITY="20GiB" MAX_CAPACITY="50GiB" DISK_TYPE="pd-standard" NAMESPACE="monitoring"
  render_and_create prometheus-data-volume.hcl.tpl

  export MIN_CAPACITY="20GiB" MAX_CAPACITY="50GiB" DISK_TYPE="pd-standard" NAMESPACE="monitoring"
  render_and_create loki-data-volume.hcl.tpl
fi

echo "Done."
