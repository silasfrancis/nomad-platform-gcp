#!/bin/bash
# nomad-jobs/plugins/deploy.sh
#
# Deploys the 3 plugin jobs (csi-controller, csi-node, nomad-autoscaler)
# against one environment's Nomad cluster. Not deployed via Octopus —
# these change rarely enough that a manual, deliberate apply beats
# wiring up a full CI pipeline for them. Run after IAP-tunneling to
# the target cluster (see platform-config's scripts/open-tunnel.sh
# dev|prod).
#
# gcp_zone/ondemand_mig_name/spot_mig_name default to this project's
# own naming convention (nomad-{env}-ondemand/nomad-{env}-spot per
# compute/main.tf) — override the last three positional args if yours
# differ.
#
# Usage: ./deploy.sh <dev|prod> <gcp-project> <artifact-registry> <image-tag> [gcp-zone] [ondemand-mig] [spot-mig]

set -euo pipefail
ENVIRONMENT="${1:?Usage: ./deploy.sh <dev|prod> <gcp-project> <artifact-registry> <image-tag> [gcp-zone] [ondemand-mig] [spot-mig]}"
GCP_PROJECT="${2:?see usage}"
ARTIFACT_REGISTRY="${3:?see usage}"
IMAGE_TAG="${4:?see usage}"
GCP_ZONE="${5:-us-central1-a}"
ONDEMAND_MIG="${6:-nomad-${ENVIRONMENT}-ondemand}"
SPOT_MIG="${7:-nomad-${ENVIRONMENT}-spot}"

if [[ "${ENVIRONMENT}" != "dev" && "${ENVIRONMENT}" != "prod" ]]; then
  echo "ERROR: environment must be 'dev' or 'prod', got '${ENVIRONMENT}'" >&2
  exit 1
fi

echo "Deploying plugins to ${ENVIRONMENT}..."

nomad job run \
  -var="environment=${ENVIRONMENT}" \
  -var="artifact_registry=${ARTIFACT_REGISTRY}" \
  -var="image_tag=${IMAGE_TAG}" \
  csi-controller.nomad.hcl

nomad job run \
  -var="environment=${ENVIRONMENT}" \
  -var="artifact_registry=${ARTIFACT_REGISTRY}" \
  -var="image_tag=${IMAGE_TAG}" \
  csi-node.nomad.hcl

nomad job run \
  -var="environment=${ENVIRONMENT}" \
  -var="gcp_project=${GCP_PROJECT}" \
  -var="artifact_registry=${ARTIFACT_REGISTRY}" \
  -var="image_tag=${IMAGE_TAG}" \
  -var="gcp_zone=${GCP_ZONE}" \
  -var="ondemand_mig_name=${ONDEMAND_MIG}" \
  -var="spot_mig_name=${SPOT_MIG}" \
  nomad-autoscaler.nomad.hcl

echo "Done."
