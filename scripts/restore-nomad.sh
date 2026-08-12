#!/usr/bin/env bash
# scripts/restore-nomad.sh
#
# Restores Nomad server state (jobs, allocations, evaluations, ACL tokens
# and policies, the Workload Identity signing keyring) from a Raft snapshot,
# per environment (dc-dev / dc-prod are separate single-server clusters,
# same split as Consul).
#
# Why this exists even though nomad-jobs/ is git-tracked: git gets you back
# the job SPECS, but not ACL tokens/policies, evaluation history, or —
# critically — the Workload Identity signing keys that Vault's jwt-nomad-*
# auth methods validate against. Redeploying every job from git after a
# server loss would also silently mint a NEW keyring, which orphans every
# JWT auth mount in Vault until they're manually repointed at the new JWKS
# endpoint. Restoring from snapshot avoids that entirely — same keyring
# comes back, Vault auth just keeps working.
#
# Reachability: nomad-{env}-server has no route from outside the VPC.
# Nomad's API is only reachable through traefik-internal, at
# nomad-{env}.platform.lefrancis.org — a private Cloud DNS hostname that
# needs an IAP tunnel into traefik-internal ITSELF before this script can
# reach it at all (see preflight_traefik_route in lib/restore-common.sh for
# the exact tunnel command it'll print if this isn't set up yet).
#
# Usage:
#   GCP_PROJECT=my-project scripts/restore-nomad.sh --env dev

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
NOMAD_HOSTNAME="nomad-${TARGET_ENV}.platform.lefrancis.org"

confirm_destructive "About to OVERWRITE Nomad server state for '$DATACENTER' — jobs, allocations, evaluations, ACL tokens/policies, and the Workload Identity signing keyring. This is a low-level Raft operation; a failure mid-restore is not designed to self-heal."

NOMAD_TOKEN="${NOMAD_TOKEN:?NOMAD_TOKEN must be set — needs the operator:write policy (or operator:snapshot-save/restore capability) for datacenter $DATACENTER}"
export NOMAD_TOKEN
export NOMAD_ADDR="${NOMAD_ADDR:-https://${NOMAD_HOSTNAME}}"

log "checking route to $NOMAD_HOSTNAME via traefik-internal"
preflight_traefik_route "$NOMAD_HOSTNAME" 443

snapshot_file=$(fetch_latest_from_gcs "nomad-snapshots/${TARGET_ENV}/" "$SCRATCH_DIR")
log "using snapshot: $snapshot_file"

log "running: nomad operator snapshot restore (datacenter=$DATACENTER)"
nomad operator snapshot restore "$snapshot_file" \
  || die "nomad operator snapshot restore failed — do not retry blindly, check 'nomad operator raft list-peers' first to confirm the server didn't drop out of quorum mid-restore"

log "restore succeeded. Post-restore checks — the keyring point matters most:"
cat <<EOF
  nomad server members                          # this server healthy and leading?
  nomad namespace list                          # all 6 present (boutique, datastore, monitoring, security, operations, plugins)?
  nomad acl policy list
  nomad operator root keyring list              # same key IDs as before the incident? (confirms Vault JWT auth wasn't orphaned)
  nomad job status -namespace=boutique frontend  # spot-check one running job
EOF

log "if this was a full server rebuild (not just a data-corruption recovery"
log "on the same node), the client nodes will need to re-join — confirm with:"
cat <<EOF
  nomad node status
EOF
log "done."
