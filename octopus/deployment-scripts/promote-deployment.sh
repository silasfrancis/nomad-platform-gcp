#!/bin/bash
# promote-deployment.sh
#
# Promotes any canary deployment(s) from deploy-to-nomad.sh, and
# cleanly no-ops for any job that wasn't a canary deploy in the first
# place.
#
# NOTE: skips both when there's no canary at all, and when there is one
# but auto_promote = true — Nomad promotes those on its own, and
# calling `nomad deployment promote` on one manually would error since
# it's not awaiting a manual promotion.
set -euo pipefail
source "$(dirname "$0")/common.sh"

# DeployedJobIds and DeploymentId__<job_id> are output variables set by
# deploy-to-nomad.sh in an earlier step, not project variables — they
# only exist under that step's own output namespace, so they're read
# back with get_octopusvariable "Octopus.Action[<step name>].Output.<var>"
# rather than as plain environment variables.
#
# VERIFY: "deploy-to-nomad" below must match that step's exact name in
# the Octopus deployment process (case-sensitive) — update it here if
# the step is ever renamed.
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
    set_octopusvariable "NomadFailureDetail" "No deployment ID recorded for ${job_id} in promote-deployment."
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
  nomad deployment promote -namespace "${NOMAD_NAMESPACE}" -no-color "${deployment_id}"

  echo "[${job_id}] promotion submitted — polling for completion..."
  for i in $(seq 1 "${MAX_ATTEMPTS}"); do
    # Captured separately from the jq parse below so a failed/cancelled
    # outcome can be debugged from the full response, not just the
    # single extracted status field.
    status_response="$(nomad deployment status -namespace "${NOMAD_NAMESPACE}" -json "${deployment_id}")"
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
        # This loop continues to other jobs rather than exiting
        # immediately, so this calls set_octopusvariable directly
        # (not fail_with_reason, which would exit here and skip
        # checking any remaining jobs).
        set_octopusvariable "NomadFailureDetail" "Deployment ${deployment_id} for ${job_id} ${status} after promotion: $(echo "${status_response}" | jq -c '{Status, StatusDescription}')"
        overall_status=1
        break
        ;;
    esac
    sleep "${SLEEP_SECONDS}"
  done
done

exit "${overall_status}"
