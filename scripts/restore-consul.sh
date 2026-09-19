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
# running agent as long as you hold a management-level ACL token. That
# token lives in Vault at kv/shared/consul/management-token (per
# vault_consumers) rather than GCP Secret Manager, because Consul comes up
# AFTER Vault in the dependency chain and can rely on Vault being available.
#
# Usage:
#   GCP_PROJECT=my-project VAULT_ADDR=https://vault.platform.lefrancis.org:8200 \
#     scripts/restore-consul.sh --env dev

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
SERVER_HOST="nomad-${TARGET_ENV}-server"   # Consul server runs alongside Nomad server, §2.1

confirm_destructive "About to OVERWRITE the Consul catalog, KV store, ACLs, and intentions for datacenter '$DATACENTER'. Services will briefly re-register as health checks re-run after restore."

VAULT_ADDR="${VAULT_ADDR:?VAULT_ADDR must be set — needed to fetch the Consul backup token}"
VAULT_TOKEN="${VAULT_TOKEN:?VAULT_TOKEN must be set — a token with read access to kv/shared/consul}"
export VAULT_ADDR VAULT_TOKEN

log "fetching Consul backup token from Vault"
CONSUL_HTTP_TOKEN=$(vault kv get -field=backup_token kv/shared/consul) \
  || die "could not read kv/shared/consul/backup_token from Vault"
export CONSUL_HTTP_TOKEN

snapshot_file=$(fetch_latest_from_gcs "consul-snapshots/${TARGET_ENV}/" "$SCRATCH_DIR")
log "using snapshot: $snapshot_file"

log "copying snapshot to $SERVER_HOST via IAP"
iap_scp_to "$snapshot_file" "$SERVER_HOST" "/tmp/consul-restore.snap"

log "running: consul snapshot restore (datacenter=$DATACENTER)"
iap_ssh "$SERVER_HOST" \
  "CONSUL_HTTP_TOKEN='$CONSUL_HTTP_TOKEN' consul snapshot restore -datacenter=$DATACENTER /tmp/consul-restore.snap && rm -f /tmp/consul-restore.snap" \
  || die "consul snapshot restore failed on $SERVER_HOST"

log "restore submitted. Verifying cluster health..."
iap_ssh "$SERVER_HOST" "CONSUL_HTTP_TOKEN='$CONSUL_HTTP_TOKEN' consul operator raft list-peers" \
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
