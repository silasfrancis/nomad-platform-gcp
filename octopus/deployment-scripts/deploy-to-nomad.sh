#!/bin/bash
# deploy-to-nomad.sh
#
# Submits every discovered job spec and captures each one's resulting
# deployment ID so later steps can poll real status instead of
# assuming success.

set -euo pipefail
source "$(dirname "$0")/common.sh"

# mapfile (not `while read < <(discover_job_files)`) so discover_job_files'
# own exit status is visible here — a process substitution runs in a
# subshell and would swallow a "no file found" failure silently.
mapfile -t job_files < <(discover_job_files)
if [ "${#job_files[@]}" -eq 0 ]; then
  exit 1
fi

deployed_job_ids=()

for job_file in "${job_files[@]}"; do
  job_id="$(job_id_from_file "${job_file}")"
  echo "Submitting ${job_file} (job \"${job_id}\") to ${NOMAD_ADDR}..."
  nomad job run -detach -no-color "${job_file}"

  sleep 2

  deployment_id="$(nomad job deployments -json "${job_id}" | jq -r '.[0].ID')"

  if [ -z "${deployment_id}" ] || [ "${deployment_id}" = "null" ]; then
    echo "Could not determine deployment ID from 'nomad job deployments ${job_id}'." >&2
    exit 1
  fi

  echo "Deployment ID for ${job_id}: ${deployment_id}"
  # Output variable, one per job, name carries the job ID so multiple
  # jobs in one package don't collide. Read back in later steps via
  # get_octopusvariable "Octopus.Action[deploy-to-nomad].Output.DeploymentId__<job_id>"
  set_octopusvariable "DeploymentId__${job_id}" "${deployment_id}"
  deployed_job_ids+=("${job_id}")
done

# Space-separated list of every job ID this step deployed, so later
# steps know which per-job DeploymentId__<job_id> variables to look up.
echo "Deployed job IDs:"
printf '  - %s\n' "${deployed_job_ids[@]}"
set_octopusvariable "DeployedJobIds" "${deployed_job_ids[*]}"
