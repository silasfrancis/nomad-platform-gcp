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
  fail_with_reason "No .nomad.hcl file found in package root."
fi

deployed_job_ids=()

for job_file in "${job_files[@]}"; do
  job_id="$(job_id_from_file "${job_file}")"
  echo "Submitting ${job_file} (job \"${job_id}\") to ${NOMAD_ADDR} (namespace ${NOMAD_NAMESPACE})..."

  set +e
  run_output="$(nomad job run -namespace "${NOMAD_NAMESPACE}" -detach -no-color "${job_file}" 2>&1)"
  run_exit=$?
  set -e
  echo "${run_output}"

  if [ "${run_exit}" -ne 0 ]; then
    fail_with_reason "Nomad job run failed for ${job_id}: $(echo "${run_output}" | tail -n 5)"
  fi

  # Give Nomad a moment to create the deployment record server-side —
  # job run returning doesn't guarantee it exists yet.
  sleep 2

  # Captured separately from the jq parse below so a missing/null ID
  # can be debugged from the raw response instead of just the
  # generic "could not determine" message.
  deployments_response="$(nomad job deployments -namespace "${NOMAD_NAMESPACE}" -json "${job_id}")"
  deployment_id="$(echo "${deployments_response}" | jq -r '.[0].ID')"
  # NOTE: relies on the API returning deployments newest-first, matching
  # the CLI table's confirmed ordering — not independently checked
  # against the raw JSON schema here, so worth a quick sanity check
  # against real output before trusting this blindly.

  if [ -z "${deployment_id}" ] || [ "${deployment_id}" = "null" ]; then
    fail_with_reason "Could not determine deployment ID from 'nomad job deployments ${job_id}'. Raw response: ${deployments_response}"
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
set_octopusvariable "DeployedJobIds" "${deployed_job_ids[*]}"
