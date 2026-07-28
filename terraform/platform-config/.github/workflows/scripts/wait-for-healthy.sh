#!/bin/bash
# wait-for-healthy.sh
#
# Polls the deployment started by deploy-to-nomad.sh until Nomad
# reports it running/successful or failed, rather than assuming success
# the moment the job was submitted.
set -euo pipefail

: "${NOMAD_ADDR:?NomadApiUrl deployment variable is required}"
: "${NOMAD_TOKEN:?NomadAclToken deployment variable is required}"
: "${DeploymentId:?DeploymentId set by deploy-to-nomad.sh is required}"

MAX_ATTEMPTS=30
SLEEP_SECONDS=10

for i in $(seq 1 "${MAX_ATTEMPTS}"); do
  status="$(nomad deployment status -no-color "${DeploymentId}" | awk '/^Status/ {print $2}')"
  echo "Attempt ${i}/${MAX_ATTEMPTS}: deployment status = ${status}"

  case "${status}" in
    successful)
      echo "Deployment healthy."
      exit 0
      ;;
    failed|cancelled)
      echo "Deployment ${status} — aborting." >&2
      exit 1
      ;;
  esac

  sleep "${SLEEP_SECONDS}"
done

echo "Timed out waiting for deployment to report healthy." >&2
exit 1
