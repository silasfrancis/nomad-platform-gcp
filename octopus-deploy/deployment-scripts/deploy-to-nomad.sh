#!/bin/bash
# deploy-to-nomad.sh
#
# Submits the rendered job spec and captures the resulting deployment
# ID so later steps can poll its status without re-parsing output.
#
# FIXED: the original version grepped the first 36-char UUID out of
# `nomad job run -detach`'s own output and assumed it was the
# deployment ID. Confirmed against real Nomad output this isn't
# reliable — the evaluation ID prints first (a separate ID from the
# deployment), and "Evaluation within deployment: <id>" only appears
# in non-detached monitoring output, which -detach explicitly skips.
# Querying `nomad job deployments` directly and taking the most recent
# entry is what the CLI itself documents this command for.
set -euo pipefail

: "${NOMAD_ADDR:?NomadApiUrl deployment variable is required}"
: "${NOMAD_TOKEN:?NomadAclToken deployment variable is required}"
: "${JOB_FILE:?path to the rendered .nomad.hcl file is required}"
: "${JOB_ID:?the job's own ID (matches job \"...\" { in the spec) is required}"

echo "Submitting ${JOB_FILE} to ${NOMAD_ADDR}..."
nomad job run -detach -no-color "${JOB_FILE}"

# Give Nomad a moment to actually create the deployment record before
# querying for it — job run returning doesn't guarantee the deployment
# object exists yet on the server side.
sleep 2

deployment_id="$(nomad job deployments -json "${JOB_ID}" | jq -r '.[0].ID')"
# NOTE: relies on the API returning deployments newest-first, matching
# the confirmed ordering of `nomad job deployments`'s own CLI table
# output — not independently verified against the JSON schema's field
# names, so worth double-checking against a real deployment before
# trusting this blindly in a production pipeline.

if [ -z "${deployment_id}" ] || [ "${deployment_id}" = "null" ]; then
  echo "Could not determine deployment ID from 'nomad job deployments ${JOB_ID}'." >&2
  exit 1
fi

echo "Deployment ID: ${deployment_id}"
echo "##octopus[setVariable name=\"DeploymentId\" value=\"${deployment_id}\"]"
