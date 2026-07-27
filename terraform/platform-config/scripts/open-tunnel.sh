#!/bin/bash
# scripts/open-tunnel.sh
#
# Opens ONLY the tunnel(s) for one target — mgmt, dev, or prod — never
# more than one environment at a time. This is the actual mechanism
# that makes "can't accidentally touch the wrong environment" true: you
# physically cannot have dev and prod tunnels open from this script in
# the same invocation.
#
# Usage: ./open-tunnel.sh <mgmt|dev|prod> <gcp-project-id> <zone>

set -euo pipefail
TARGET="${1:?Usage: $0 <mgmt|dev|prod> <gcp-project-id> <zone>}"
PROJECT_ID="${2:?Usage: $0 <mgmt|dev|prod> <gcp-project-id> <zone>}"
ZONE="${3:?Usage: $0 <mgmt|dev|prod> <gcp-project-id> <zone>}"

case "${TARGET}" in
  mgmt)
    gcloud compute start-iap-tunnel mgmt-vm 8200 \
      --local-host-port=localhost:8200 --zone="${ZONE}" --project="${PROJECT_ID}" &
    echo "mgmt: Vault tunnel open on localhost:8200."
    ;;
  dev)
    gcloud compute start-iap-tunnel nomad-dev-server-0 8500 \
      --local-host-port=localhost:18500 --zone="${ZONE}" --project="${PROJECT_ID}" &
    gcloud compute start-iap-tunnel nomad-dev-server-0 4646 \
      --local-host-port=localhost:14646 --zone="${ZONE}" --project="${PROJECT_ID}" &
    echo "dev: Consul (18500) + Nomad (14646) tunnels open."
    ;;
  prod)
    gcloud compute start-iap-tunnel nomad-prod-server-0 8500 \
      --local-host-port=localhost:18501 --zone="${ZONE}" --project="${PROJECT_ID}" &
    gcloud compute start-iap-tunnel nomad-prod-server-0 4646 \
      --local-host-port=localhost:14647 --zone="${ZONE}" --project="${PROJECT_ID}" &
    echo "prod: Consul (18501) + Nomad (14647) tunnels open."
    ;;
  *)
    echo "ERROR: target must be mgmt, dev, or prod" >&2
    exit 1
    ;;
esac

sleep 3
echo "Verify with: jobs -l. Run scripts/close-tunnels.sh when the apply is done."
