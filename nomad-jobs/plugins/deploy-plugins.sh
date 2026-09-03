#!/bin/bash
#
# Deploys the 3 plugin jobs (csi-controller, csi-node, nomad-autoscaler)
# against one environment's Nomad cluster. Not deployed via Octopus —
# these change rarely enough that a manual, deliberate apply beats
# wiring up a full CI pipeline for them. Run after IAP-tunneling to
# the target cluster (see platform-config's scripts/open-tunnel.sh
# dev|prod).
#
# Usage:
#  cd nomad-jobs/plugins
# export NOMAD_ADDR="https://nomad-dev.platform.lefrancis.org:8444" 
# export NOMAD_TOKEN="<nomad-token>"
# ./deploy-plugins.sh <dev|prod> <gcp-project> <gcp-region> [min-ondemand] [max-ondemand] [min-spot] [max-spot]

set -euo pipefail
ENVIRONMENT="${1:?Usage: ./deploy.sh <dev|prod> <gcp-project> <artifact-registry> <image-tag> [gcp-zone] [ondemand-mig] [spot-mig]}"
GCP_PROJECT="${2:?see usage}"
GCP_REGION="${3:-europe-west1}"
MIN_ONDEMAND_INSTANCES="${4:-1}"
MAX_ONDEMAND_INSTANCES="${5:-10}"
MIN_SPOT_INSTANCES="${6:-0}"
MAX_SPOT_INSTANCES="${7:-10}"

if [[ "${ENVIRONMENT}" != "dev" && "${ENVIRONMENT}" != "prod" ]]; then
  echo "ERROR: environment must be 'dev' or 'prod', got '${ENVIRONMENT}'" >&2
  exit 1
fi

echo "Deploying plugins to ${ENVIRONMENT}..."

nomad job run \
  -detach \
  -var="environment=${ENVIRONMENT}" \
  csi-controller.nomad.hcl

nomad job run \
  -detach \
  -var="environment=${ENVIRONMENT}" \
  csi-node.nomad.hcl

nomad job run \
  -detach \
  -var="environment=${ENVIRONMENT}" \
  -var="gcp_project=${GCP_PROJECT}" \
  -var="gcp_region=${GCP_REGION}" \
  -var="min_ondemand_instances=${MIN_ONDEMAND_INSTANCES}" \
  -var="max_ondemand_instances=${MAX_ONDEMAND_INSTANCES}" \
  -var="min_spot_instances=${MIN_SPOT_INSTANCES}" \
  -var="max_spot_instances=${MAX_SPOT_INSTANCES}" \
  nomad-autoscaler.nomad.hcl

echo "Done."
