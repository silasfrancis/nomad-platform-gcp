#!/bin/bash
# wait-for-healthy.sh
#
# Polls every deployment started by deploy-to-nomad.sh until Nomad
# reports it healthy or failed, rather than assuming success the
# moment the jobs were submitted.

set -euo pipefail
source "$(dirname "$0")/common.sh"

: "${DeployedJobIds:?DeployedJobIds set by deploy-to-nomad.sh is required}"

MAX_ATTEMPTS=30
SLEEP_SECONDS=10
overall_status=0

for job_id in ${DeployedJobIds}; do
  deployment_var="DeploymentId__${job_id}"
  deployment_id="${!deployment_var:-}"

  if [ -z "${deployment_id}" ]; then
    echo "No deployment ID recorded for ${job_id} — skipping." >&2
    overall_status=1
    continue
  fi

  echo "Watching deployment ${deployment_id} (job ${job_id})..."
  job_healthy=0

  for i in $(seq 1 "${MAX_ATTEMPTS}"); do
    status="$(nomad deployment status -json "${deployment_id}" | jq -r '.Status')"
    echo "  [${job_id}] attempt ${i}/${MAX_ATTEMPTS}: deployment status = ${status}"

    case "${status}" in
      successful)
        echo "  [${job_id}] deployment healthy (successful)."
        job_healthy=1
        break
        ;;
      running)
        if job_has_canary "${job_id}"; then
          echo "  [${job_id}] canary healthy, awaiting promotion (handled by promote-deployment.sh next)."
          job_healthy=1
          break
        fi
        # Plain rolling update still finishing — not terminal, keep polling.
        ;;
      failed|cancelled)
        echo "  [${job_id}] deployment ${status} — aborting." >&2
        overall_status=1
        break
        ;;
    esac

    sleep "${SLEEP_SECONDS}"
  done

  if [ "${job_healthy}" -ne 1 ] && [ "${overall_status}" -eq 0 ]; then
    echo "  [${job_id}] timed out waiting for deployment to report healthy." >&2
    overall_status=1
  fi
done

exit "${overall_status}"