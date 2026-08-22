#!/bin/bash
# scripts/open-tunnel.sh
#
# Opens ONLY the tunnel for one target — mgmt, dev, or prod — never
# more than one environment at a time. This is the actual mechanism
# that makes "can't accidentally touch the wrong environment" true: you
# physically cannot have dev and prod tunnels open from this script in
# the same invocation.
#
# Every target now tunnels to the SAME VM — traefik-internal — just a
# different port for its own instance (mgmt/dev-internal/prod-internal
# each run as an independent process there). There is no more direct
# tunnel to mgmt-vm or to any Nomad/Consul server: Consul's operator
# token already exists on traefik-internal via Ansible before any of
# this is ever needed, so Terraform only ever needs to reach Traefik's
# static passthrough routes, same as everything else.
#
# Requires the hostnames below to resolve to 127.0.0.1 locally first —
# run scripts/update-hosts.sh once if you haven't already.
#
# Usage: ./open-tunnel.sh <mgmt|dev|prod> <gcp-project-id> <zone>

set -euo pipefail
TARGET="${1:?Usage: $0 <mgmt|dev|prod> <gcp-project-id> <zone>}"
PROJECT_ID="${2:?Usage: $0 <mgmt|dev|prod> <gcp-project-id> <zone>}"
ZONE="${3:?Usage: $0 <mgmt|dev|prod> <gcp-project-id> <zone>}"

case "${TARGET}" in
  mgmt)
    gcloud compute start-iap-tunnel traefik-internal 8443 \
      --local-host-port=localhost:8443 --zone="${ZONE}" --project="${PROJECT_ID}" &
    echo "mgmt: traefik-internal's mgmt instance open on localhost:8443 (vault/octopus/grafana)."
    ;;
  dev)
    gcloud compute start-iap-tunnel traefik-internal 8444 \
      --local-host-port=localhost:8444 --zone="${ZONE}" --project="${PROJECT_ID}" &
    echo "dev: traefik-internal's dev-internal instance open on localhost:8444 (consul-dev + nomad-dev, same port, Host-routed)."
    ;;
  prod)
    gcloud compute start-iap-tunnel traefik-internal 8445 \
      --local-host-port=localhost:8445 --zone="${ZONE}" --project="${PROJECT_ID}" &
    echo "prod: traefik-internal's prod-internal instance open on localhost:8445 (consul-prod + nomad-prod, same port, Host-routed)."
    ;;
  *)
    echo "ERROR: target must be mgmt, dev, or prod" >&2
    exit 1
    ;;
esac

sleep 3
echo "Run scripts/close-tunnels.sh when the apply is done."
