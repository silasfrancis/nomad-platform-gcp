#!/bin/bash
# promote-deployment.sh
#
# Promotes any canary deployment(s) from deploy-to-nomad.sh, and
# cleanly no-ops for any job that wasn't a canary deploy in the first
# place.

# NOTE: this checks canary > 0 only, per the agreed design — it does
# NOT currently check `update.auto_promote`. A job with canary > 0 but
# auto_promote = true has Nomad promote itself automatically; calling
# `nomad deployment promote` on one of those will error since it's not
# awaiting a manual promotion. Worth deciding whether to add an
# AutoPromote check here before this runs against a real auto-promote
# job — flagging rather than silently adding untested logic beyond
# what was asked for.
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

  if ! job_has_canary "${job_id}"; then
    echo "[${job_id}] not a canary deployment — nothing to promote."
    continue
  fi

  echo "[${job_id}] promoting deployment ${deployment_id}..."
  nomad deployment promote -no-color "${deployment_id}"

  echo "[${job_id}] promotion submitted — polling for completion..."
  for i in $(seq 1 "${MAX_ATTEMPTS}"); do
    status="$(nomad deployment status -json "${deployment_id}" | jq -r '.Status')"
    echo "  [${job_id}] attempt ${i}/${MAX_ATTEMPTS}: deployment status = ${status}"

    case "${status}" in
      successful)
        echo "  [${job_id}] promotion complete."
        break
        ;;
      failed|cancelled)
        echo "  [${job_id}] deployment ${status} after promotion — aborting." >&2
        overall_status=1
        break
        ;;
    esac
    sleep "${SLEEP_SECONDS}"
  done
done

exit "${overall_status}"