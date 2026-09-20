#!/bin/bash
# scripts/open-tunnel.sh
#
# Opens ONLY the tunnel(s) for one target — mgmt, dev, or prod — never
# more than one environment at a time. This is the actual mechanism
# that makes "can't accidentally touch the wrong environment" true: you
# physically cannot have dev and prod tunnels open from this script in
# the same invocation.
#
# Every target tunnels to the SAME VM — traefik-internal — just different
# ports for that environment's own Traefik instance (mgmt/dev-internal/
# prod-internal each run as an independent process there, per
# traefik_instance_catalog). dev/prod each open THREE ports at once:
#   - the admin-UI port (nomad-{env} + consul-{env}, Host-routed)
#   - the internal-services port (falco-webhook, nomad-sentinel, loki,
#     prometheus, metrics-api — anything routed via that env's
#     consulCatalog provider on the "internal" entrypoint)
#   - the Postgres TCP passthrough port
#
# Requires the hostnames below to resolve to 127.0.0.1 locally first —
# run scripts/update-hosts.sh once if you haven't already (it will need
# the internal-services and postgres-{env} hostnames added too, if it
# doesn't have them yet).
#
# Usage: ./open-tunnel.sh <mgmt|dev|prod> <gcp-project-id> <zone>

set -euo pipefail
TARGET="${1:?Usage: $0 <mgmt|dev|prod> <gcp-project-id> <zone>}"
PROJECT_ID="${2:?Usage: $0 <mgmt|dev|prod> <gcp-project-id> <zone>}"
ZONE="${3:?Usage: $0 <mgmt|dev|prod> <gcp-project-id> <zone>}"

open_port() {
  local port="$1" label="$2"
  gcloud compute start-iap-tunnel traefik-internal "$port" \
    --local-host-port="localhost:${port}" --zone="${ZONE}" --project="${PROJECT_ID}" &
  echo "  localhost:${port} — ${label}"
}

case "${TARGET}" in
  mgmt)
    echo "mgmt: traefik-internal's mgmt instance —"
    open_port 8443 "vault/octopus/grafana"
    ;;
  dev)
    echo "dev: traefik-internal's dev-internal instance —"
    open_port 8444 "consul-dev + nomad-dev admin UIs, Host-routed"
    open_port 8446 "internal services (falco-webhook, nomad-sentinel, loki, prometheus, metrics-api)"
    open_port 15432 "Postgres TCP passthrough"
    ;;
  prod)
    echo "prod: traefik-internal's prod-internal instance —"
    open_port 8445 "consul-prod + nomad-prod admin UIs, Host-routed"
    open_port 8447 "internal services (falco-webhook, nomad-sentinel, loki, prometheus, metrics-api)"
    open_port 15433 "Postgres TCP passthrough"
    ;;
  *)
    echo "ERROR: target must be mgmt, dev, or prod" >&2
    exit 1
    ;;
esac

sleep 3
echo "Run scripts/close-tunnels.sh when the apply is done."
