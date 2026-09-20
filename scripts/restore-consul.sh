#!/usr/bin/env bash
# scripts/restore-consul.sh
#
# Restores Consul from a snapshot into the given environment's datacenter
# (dc-dev or dc-prod — these are two entirely separate single-server
# clusters, unlike Vault which is one shared instance). Restoring dev never
# touches prod's catalog, ACLs, or intentions, and vice versa.
#
# Consul's restore, unlike Vault's, does NOT require the node to be freshly
# initialized first — `consul snapshot restore` works against a live,
# running agent as long as you hold a management-level ACL token.
#
# That token comes from GCP Secret Manager (consul-snapshot-token-${env}),
# NOT Vault — deliberately. Consul must be restorable even when Vault is
# the thing that's down (or is itself mid-restore), so this can't depend on
# Vault being reachable. Same token the nightly consul-snapshot Nomad batch
# job uses for `snapshot save`; it also carries `snapshot-force` (restore)
# capability.
#
# Reachability: nomad-{env}-server has no route from outside the VPC.
# Consul's API is only reachable through traefik-internal, at
# consul-{env}.platform.lefrancis.org — a private Cloud DNS hostname that
# needs an IAP tunnel into traefik-internal ITSELF before this script can
# reach it at all (see preflight_traefik_route in lib/restore-common.sh for
# the exact tunnel command it'll print if this isn't set up yet).
#
# Usage:
#   GCP_PROJECT=my-project scripts/restore-consul.sh --env dev

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=lib/restore-common.sh
source lib/restore-common.sh

TARGET_ENV=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --env) TARGET_ENV="$2"; shift 2 ;;
    --yes) ASSUME_YES=1; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done
require_env "$TARGET_ENV"

DATACENTER="dc-${TARGET_ENV}"
CONSUL_HOSTNAME="consul-${TARGET_ENV}.platform.lefrancis.org"
# dev-internal / prod-internal are two separate Traefik processes on
# traefik-internal, each on their own port — not a shared 443.
case "$TARGET_ENV" in
  dev)  CONSUL_PORT="8444" ;;
  prod) CONSUL_PORT="8445" ;;
esac

confirm_destructive "About to OVERWRITE the Consul catalog, KV store, ACLs, and intentions for datacenter '$DATACENTER'. Services will briefly re-register as health checks re-run after restore."

# consul-snapshot-token-${env} (GCP Secret Manager), not Vault — see header.
# A manually-exported CONSUL_HTTP_TOKEN still wins if already set (e.g. a
# personal management token during a DR drill).
if [[ -z "${CONSUL_HTTP_TOKEN:-}" ]]; then
  log "CONSUL_HTTP_TOKEN not set — fetching consul-snapshot-token-${TARGET_ENV} from GCP Secret Manager"
  CONSUL_HTTP_TOKEN=$(fetch_gcp_secret "consul-snapshot-token-${TARGET_ENV}")
fi
export CONSUL_HTTP_TOKEN
export CONSUL_HTTP_ADDR="${CONSUL_HTTP_ADDR:-https://${CONSUL_HOSTNAME}:${CONSUL_PORT}}"

log "checking route to ${CONSUL_HOSTNAME}:${CONSUL_PORT} via traefik-internal"
preflight_traefik_route "$CONSUL_HOSTNAME" "$CONSUL_PORT"

snapshot_file=$(fetch_latest_from_gcs "consul-snapshots/${TARGET_ENV}/" "$SCRATCH_DIR")
log "using snapshot: $snapshot_file"

log "running: consul snapshot restore (datacenter=$DATACENTER)"
consul snapshot restore -datacenter="$DATACENTER" "$snapshot_file" \
  || die "consul snapshot restore failed — do not retry blindly, check 'consul operator raft list-peers' first to confirm the server didn't drop out of quorum mid-restore"

log "restore submitted. Verifying cluster health..."
consul operator raft list-peers -datacenter="$DATACENTER" \
  || warn "could not confirm raft peers — check manually, this alone is not fatal on a single-server datacenter"

log "manual follow-up checks (service catalog takes a few health-check"
log "intervals to settle, don't judge it from the first read):"
cat <<EOF
  consul catalog services -datacenter=$DATACENTER
  consul acl token list -datacenter=$DATACENTER | head
  consul intention check <src> <dst> -datacenter=$DATACENTER   # spot-check one mesh pair, e.g. frontend -> recommendationservice
  # Confirm Nomad's own service discovery is functional end to end:
  dig @127.0.0.1 -p 8600 frontend.service.consul
EOF
log "done."
