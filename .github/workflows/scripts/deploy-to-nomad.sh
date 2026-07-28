#!/bin/bash
# deploy-to-nomad.sh
#
# Submits the rendered job spec and captures the resulting deployment
# ID so later steps can poll its status without re-parsing output.
set -euo pipefail

: "${NOMAD_ADDR:?NomadApiUrl deployment variable is required}"
: "${NOMAD_TOKEN:?NomadAclToken deployment variable is required}"
: "${JOB_FILE:?path to the rendered .nomad.hcl file is required}"

echo "Submitting ${JOB_FILE} to ${NOMAD_ADDR}..."
run_output="$(nomad job run -detach -no-color "${JOB_FILE}")"
echo "${run_output}"

deployment_id="$(echo "${run_output}" | grep -oE '[a-f0-9-]{36}' | head -1)"
if [ -z "${deployment_id}" ]; then
  echo "Could not determine deployment ID from nomad job run output." >&2
  exit 1
fi

echo "##octopus[setVariable name=\"DeploymentId\" value=\"${deployment_id}\"]"
