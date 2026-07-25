#!/bin/bash
# scripts/open-tunnels.sh
#
# Opens persistent IAP tunnels for Consul + Nomad's dev/prod APIs onto
# fixed local ports. Must stay open for the ENTIRE terraform apply in
# consul/ and nomad/ — both providers hold one live connection across
# every resource in a run. Run this before apply, close-tunnels.sh after.
#
# NOTE: instance names below assume the single static nomad-{env}-server
# VM naming from compute/ — adjust "nomad-prod-server-0" if the actual
# instance-group-generated name differs (prod can run up to 3 servers
# per nomad_server_count; any one of the three works for tunneling).
#
# Usage: ./open-tunnels.sh <gcp-project-id> <zone>

set -euo pipefail
PROJECT_ID="${1:?Usage: $0 <gcp-project-id> <zone>}"
ZONE="${2:?Usage: $0 <gcp-project-id> <zone>}"

gcloud compute start-iap-tunnel nomad-dev-server 8500 \
  --local-host-port=localhost:18500 --zone="${ZONE}" --project="${PROJECT_ID}" &

gcloud compute start-iap-tunnel nomad-prod-server-0 8500 \
  --local-host-port=localhost:18501 --zone="${ZONE}" --project="${PROJECT_ID}" &

gcloud compute start-iap-tunnel nomad-dev-server 4646 \
  --local-host-port=localhost:14646 --zone="${ZONE}" --project="${PROJECT_ID}" &

gcloud compute start-iap-tunnel nomad-prod-server-0 4646 \
  --local-host-port=localhost:14647 --zone="${ZONE}" --project="${PROJECT_ID}" &

sleep 3
echo "4 tunnels launched in background. Verify with: jobs -l"
echo "Run scripts/close-tunnels.sh when the apply is done."
