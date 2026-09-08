#!/bin/bash
# wait-for-healthy.sh
#
# Polls every deployment started by deploy-to-nomad.sh until Nomad
# reports it healthy or failed, rather than assuming success the
# moment the jobs were submitted.

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
# Empty (not unset — reaching this step at all means deploy-to-nomad.sh
# ran to completion and unconditionally called set_octopusvariable on
# this name) legitimately means "no service-type jobs in this package" —
# deploy-to-nomad.sh only adds a job ID here for `type = "service"`
# jobs; batch/system/sysbatch jobs register and run but have no
# Deployment object to wait on at all, so there's nothing to check.
# That's success, not an error — exit cleanly rather than failing.
if [ -z "${DeployedJobIds}" ]; then
  echo "No service-type jobs were deployed (only batch/system/sysbatch, or none at all) — nothing to wait for."
  exit 0
fi

MAX_ATTEMPTS=30
SLEEP_SECONDS=10
overall_status=0

for job_id in ${DeployedJobIds}; do
  deployment_id="$(get_octopusvariable "Octopus.Action[${DEPLOY_STEP_NAME}].Output.DeploymentId__${job_id}")"

  if [ -z "${deployment_id}" ]; then
    echo "No deployment ID recorded for ${job_id} — skipping." >&2
    set_octopusvariable "NomadFailureDetail" "No deployment ID recorded for ${job_id} in wait-for-healthy."
    overall_status=1
    continue
  fi

  echo "Watching deployment ${deployment_id} (job ${job_id})..."
  job_healthy=0

  for i in $(seq 1 "${MAX_ATTEMPTS}"); do
    # Captured separately from the jq parse below so a failed/cancelled
    # outcome can be debugged from the full response, not just the
    # single extracted status field.
    status_response="$(nomad deployment status -namespace "${NOMAD_NAMESPACE}" -json "${deployment_id}")"
    status="$(echo "${status_response}" | jq -r '.Status')"
    echo "  [${job_id}] attempt ${i}/${MAX_ATTEMPTS}: deployment status = ${status}"

    case "${status}" in
      successful)
        echo "  [${job_id}] deployment healthy (successful)."
        job_healthy=1
        break
        ;;
      running)
        if job_has_canary "${job_id}"; then
          # job_has_canary only tells us this job's SPEC uses canaries —
          # it says nothing about whether the canary placed by THIS
          # deployment has actually passed its health check yet.
          # Status stays "running" for the entire canary window: from
          # the moment the canary allocation is placed (HealthyAllocs=0)
          # all the way through to it being confirmed healthy, and even
          # after promotion. Nomad's own docs show a deployment reported
          # as "requires manual promotion" while HealthyAllocs is still
          # 0 for the canary group, so the coarse Status/Description
          # text can't be trusted here either — checking the actual
          # per-task-group HealthyAllocs/DesiredCanaries counts already
          # present in status_response is what actually tells us the
          # canary is ready. Without this check, promote-deployment.sh
          # can be called before Nomad has finished bringing the canary
          # up, which fails with "Task group has 0/1 healthy allocations".
          canary_ready="$(echo "${status_response}" | jq -r '
            [.TaskGroups[]? | select((.DesiredCanaries // 0) > 0)] as $canary_groups
            | (($canary_groups | length) > 0) and ($canary_groups | all(.HealthyAllocs >= .DesiredCanaries))
          ')"
          if [ "${canary_ready}" = "true" ]; then
            echo "  [${job_id}] canary healthy, awaiting promotion (handled by promote-deployment.sh next)."
            job_healthy=1
            break
          fi
          echo "  [${job_id}] canary placed but not yet confirmed healthy — still polling."
        fi
        # Plain rolling update still finishing, or canary not yet
        # healthy — not terminal, keep polling.
        ;;
      failed|cancelled)
        echo "  [${job_id}] deployment ${status} — aborting. Raw status response:" >&2
        echo "${status_response}" >&2
        # This loop continues to other jobs rather than exiting
        # immediately, so this calls set_octopusvariable directly
        # (not fail_with_reason, which would exit here and skip
        # checking any remaining jobs).
        set_octopusvariable "NomadFailureDetail" "Deployment ${deployment_id} for ${job_id} ${status}: $(echo "${status_response}" | jq -c '{Status, StatusDescription}')"
        overall_status=1
        break
        ;;
    esac

    sleep "${SLEEP_SECONDS}"
  done

  if [ "${job_healthy}" -ne 1 ] && [ "${overall_status}" -eq 0 ]; then
    echo "  [${job_id}] timed out waiting for deployment to report healthy." >&2
    set_octopusvariable "NomadFailureDetail" "Deployment ${deployment_id} for ${job_id} timed out waiting for healthy status."
    overall_status=1
  fi
done

exit "${overall_status}"
