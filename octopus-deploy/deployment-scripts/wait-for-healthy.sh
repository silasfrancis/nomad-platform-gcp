#!/bin/bash
# wait-for-healthy.sh
#
# Polls the deployment started by deploy-to-nomad.sh until Nomad
# reports it running/successful or failed, rather than assuming success
# the moment the job was submitted.
#
# FIXED: the original awk '/^Status/ {print $2}' grabbed the literal
# "=" sign, not the status value — confirmed against real Nomad output
# ("Status      = running" splits as $1=Status, $2==, $3=running).
# Every poll printed an empty/wrong value, so the case statement below
# never matched anything and this always ran until timeout regardless
# of the deployment's real outcome. Switched to -json + jq, which
# doesn't depend on the CLI's column layout at all.
set -euo pipefail

: "${NOMAD_ADDR:?NomadApiUrl deployment variable is required}"
: "${NOMAD_TOKEN:?NomadAclToken deployment variable is required}"
: "${DeploymentId:?DeploymentId set by deploy-to-nomad.sh is required}"

MAX_ATTEMPTS=30
SLEEP_SECONDS=10

for i in $(seq 1 "${MAX_ATTEMPTS}"); do
  status="$(nomad deployment status -json "${DeploymentId}" | jq -r '.Status')"
  echo "Attempt ${i}/${MAX_ATTEMPTS}: deployment status = ${status}"

  case "${status}" in
    successful)
      echo "Deployment healthy."
      exit 0
      ;;
    # "running" alone isn't terminal for a canary deployment — it
    # means "waiting to be promoted," which promote-deployment.sh
    # handles as its own separate step. Only actual terminal failure
    # states stop this loop early.
    failed|cancelled)
      echo "Deployment ${status} — aborting." >&2
      exit 1
      ;;
  esac

  sleep "${SLEEP_SECONDS}"
done

echo "Timed out waiting for deployment to report healthy." >&2
exit 1
