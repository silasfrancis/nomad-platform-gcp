#!/bin/bash
# promote-deployment.sh
#
# Promotes any canary deployment(s) from deploy-to-nomad.sh, and
# cleanly no-ops for any job that wasn't a canary deploy in the first
# place.
set -euo pipefail
source "$(dirname "$0")/common.sh"

# DeployedJobIds and DeploymentId__<job_id> are output variables set by
# deploy-to-nomad.sh in an earlier step, not project variables — they
# only exist under that step's own output namespace, so they're read
# back with get_octopusvariable "Octopus.Action[<step name>].Output.<var>"
# rather than as plain environment variables.

DEPLOY_STEP_NAME="deploy-to-nomad"

DeployedJobIds="$(get_octopusvariable "Octopus.Action[${DEPLOY_STEP_NAME}].Output.DeployedJobIds")"
: "${DeployedJobIds:?DeployedJobIds set by deploy-to-nomad.sh is required}"

MAX_ATTEMPTS=30
SLEEP_SECONDS=10
overall_status=0

for job_id in ${DeployedJobIds}; do
  deployment_id="$(get_octopusvariable "Octopus.Action[${DEPLOY_STEP_NAME}].Output.DeploymentId__${job_id}")"

  if [ -z "${deployment_id}" ]; then
    echo "No deployment ID recorded for ${job_id} — skipping." >&2
    overall_status=1
    continue
  fi

  if ! job_has_canary "${job_id}"; then
    echo "[${job_id}] not a canary deployment — nothing to promote."
    continue
  fi

  if job_auto_promotes "${job_id}"; then
    echo "[${job_id}] canary with auto_promote=true — Nomad promotes this on its own, nothing to do here."
    continue
  fi

  echo "[${job_id}] promoting deployment ${deployment_id}..."
  nomad deployment promote -no-color "${deployment_id}"

  echo "[${job_id}] promotion submitted — polling for completion..."
  for i in $(seq 1 "${MAX_ATTEMPTS}"); do
    status_response="$(nomad deployment status -json "${deployment_id}")"
    status="$(echo "${status_response}" | jq -r '.Status')"
    echo "  [${job_id}] attempt ${i}/${MAX_ATTEMPTS}: deployment status = ${status}"

    case "${status}" in
      successful)
        echo "  [${job_id}] promotion complete."
        break
        ;;
      failed|cancelled)
        echo "  [${job_id}] deployment ${status} after promotion — aborting. Raw status response:" >&2
        echo "${status_response}" >&2
        overall_status=1
        break
        ;;
    esac
    sleep "${SLEEP_SECONDS}"
  done
done

exit "${overall_status}"
