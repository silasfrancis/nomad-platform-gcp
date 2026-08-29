#!/bin/bash
# deploy-to-nomad.sh
#
# Submits every discovered job spec and captures each one's resulting
# deployment ID so later steps can poll real status instead of
# assuming success.

set -euo pipefail
source "$(dirname "$0")/common.sh"

deployed_job_ids=()

while IFS= read -r job_file; do
  job_id="$(job_id_from_file "${job_file}")"
  echo "Submitting ${job_file} (job \"${job_id}\") to ${NOMAD_ADDR}..."
  nomad job run -detach -no-color "${job_file}"

  # Give Nomad a moment to create the deployment record server-side —
  # job run returning doesn't guarantee it exists yet.
  sleep 2

  deployment_id="$(nomad job deployments -json "${job_id}" | jq -r '.[0].ID')"
  # NOTE: relies on the API returning deployments newest-first, matching
  # the CLI table's confirmed ordering — not independently checked
  # against the raw JSON schema here, so worth a quick sanity check
  # against real output before trusting this blindly.

  if [ -z "${deployment_id}" ] || [ "${deployment_id}" = "null" ]; then
    echo "Could not determine deployment ID from 'nomad job deployments ${job_id}'." >&2
    exit 1
  fi

  echo "Deployment ID for ${job_id}: ${deployment_id}"
  echo "##octopus[setVariable name=\"DeploymentId__${job_id}\" value=\"${deployment_id}\"]"
  deployed_job_ids+=("${job_id}")
done < <(discover_job_files)

echo "##octopus[setVariable name=\"DeployedJobIds\" value=\"${deployed_job_ids[*]}\"]"