#!/bin/bash
# promote-deployment.sh
#
# Promotes a canary deployment once wait-for-healthy.sh has confirmed
# it's healthy. Required for every job using update { canary = N }
# with auto_promote = false — that's frontend/checkoutservice/
# cartservice/productcatalogservice (real canary) and metrics-api/
# nomad-sentinel (native blue-green via canary = count, per this
# session's redesign away from the earlier #{DeploymentSlot} approach).
# All 6 set auto_promote = false deliberately — a human/Octopus
# decides when to cut over, Nomad never does it automatically.
#
# Only wire this step into those 6 projects' own Octopus deployment
# processes. Plain rolling-update jobs (the other 15 across boutique/
# monitoring/security/operations) have no canary concept at all —
# there's nothing to promote, and running this against one of them
# would just fail against a deployment that was never waiting on a
# promotion in the first place.
set -euo pipefail

: "${NOMAD_ADDR:?NomadApiUrl deployment variable is required}"
: "${NOMAD_TOKEN:?NomadAclToken deployment variable is required}"
: "${DeploymentId:?DeploymentId set by deploy-to-nomad.sh is required}"

echo "Promoting deployment ${DeploymentId}..."
nomad deployment promote -no-color "${DeploymentId}"

echo "Promotion submitted — polling for the old allocations to actually stop..."

MAX_ATTEMPTS=30
SLEEP_SECONDS=10

for i in $(seq 1 "${MAX_ATTEMPTS}"); do
  status="$(nomad deployment status -json "${DeploymentId}" | jq -r '.Status')"
  echo "Attempt ${i}/${MAX_ATTEMPTS}: deployment status = ${status}"

  case "${status}" in
    successful)
      echo "Promotion complete — deployment successful."
      exit 0
      ;;
    failed|cancelled)
      echo "Deployment ${status} after promotion — aborting." >&2
      exit 1
      ;;
  esac

  sleep "${SLEEP_SECONDS}"
done

echo "Timed out waiting for promoted deployment to complete." >&2
exit 1
