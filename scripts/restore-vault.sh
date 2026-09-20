#!/usr/bin/env bash
# scripts/restore-vault.sh
#
# Restores Vault from a Raft snapshot onto mgmt-vm.
#
# IMPORTANT — why this does NOT follow HashiCorp's standard cold-restore
# runbook: that runbook ("target node sealed, empty raft dir, other nodes
# stopped, then vault operator raft snapshot restore -force") is written for
# HA clusters where you're bringing a peer back in sync. This project runs a
# single Vault node with GCP KMS auto-unseal (§3.1) — there is no peer to
# keep stopped, and a "sealed" node isn't a stable state to work against
# because auto-unseal fires the moment the process starts and can reach KMS.
#
# The path that actually works here has two distinct scenarios:
#
#   SAME NODE, DATA CORRUPTION (Vault process still up, already unsealed):
#     Just call the restore API against the running leader with -force.
#     No init needed — you already have a live sudo-capable token.
#
#   FRESH / REPLACEMENT NODE (full mgmt-vm loss — Terraform + Ansible have
#   already rebuilt the VM and installed Vault with the seal "gcpckms" {}
#   stanza pointed at the same KMS key ring before this script runs):
#     A brand-new Raft store has no data yet, so there's nothing for a
#     token to authenticate against. `vault operator init` bootstraps a
#     throwaway root token good for exactly one thing: making the
#     authenticated restore call. Auto-unseal via GCP KMS means init
#     doesn't hand back unseal keys to manage — just recovery keys, which
#     this script discards along with the throwaway token once the restore
#     succeeds. Post-restore verification switches to the ORIGINAL root
#     token from before the incident, held in Secret Manager
#     (`vault-root-token`) since Vault itself isn't a valid source for it
#     at this point.
#
# Usage:
#   GCP_PROJECT=my-project scripts/restore-vault.sh [--fresh-node]
#
#   --fresh-node   This is a full node rebuild (Scenario 2 above). Without
#                  this flag the script assumes Scenario 1 (same node,
#                  already unsealed) and will refuse to run `operator init`.
#
#   GCP_ZONE defaults to europe-west1-b (where mgmt-vm actually lives) —
#   override it if that ever changes.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=lib/restore-common.sh
source lib/restore-common.sh
require_cli vault

FRESH_NODE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --fresh-node) FRESH_NODE=1; shift ;;
    --yes) ASSUME_YES=1; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done

VAULT_HOSTNAME="vault.platform.lefrancis.org"
VAULT_PORT="8443"   # mgmt Traefik instance's https_port, per traefik_instance_catalog
VAULT_ADDR="${VAULT_ADDR:-https://${VAULT_HOSTNAME}:${VAULT_PORT}}"
export VAULT_ADDR

# Reachability: vault.platform.lefrancis.org is a private Cloud DNS hostname,
# only reachable through traefik-internal (no public IP on that VM), on its
# mgmt instance's port (8443 — distinct from the dev/prod internal instances'
# 8444/8445). Needs an IAP tunnel into traefik-internal ITSELF before this
# script can reach it — preflight_traefik_route prints the exact tunnel
# command if it isn't set up yet.
log "checking route to ${VAULT_HOSTNAME}:${VAULT_PORT} via traefik-internal"
preflight_traefik_route "$VAULT_HOSTNAME" "$VAULT_PORT"

confirm_yesno "About to OVERWRITE the live Vault instance (mgmt-vm) with a Raft snapshot — this is the ONE shared Vault instance for both dev and prod, so this replaces ALL secrets engines, policies, auth methods, and the encryption keyring for both. Any token created AFTER the snapshot's timestamp — including vault-root-token and vault-operator-token in Secret Manager — will stop working post-restore; recovering from that needs the ORIGINAL vault-recovery-keys (from initial setup, not a --fresh-node drill) to run vault operator generate-root."

snapshot_file=$(fetch_latest_from_gcs "vault-snapshots/" "$SCRATCH_DIR")
log "using snapshot: $snapshot_file"

if [[ "$FRESH_NODE" == "1" ]]; then
  log "fresh-node mode: bootstrapping a throwaway root token to authenticate the restore call"
  init_output=$(vault operator init -format=json -recovery-shares=1 -recovery-threshold=1) \
    || die "vault operator init failed — check the gcpckms seal stanza was applied by Ansible before running this script"
  throwaway_root_token=$(echo "$init_output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["root_token"])')
  export VAULT_TOKEN="$throwaway_root_token"
  log "throwaway token acquired"
else
  # vault-snapshot-token (GCP Secret Manager) is the same token the nightly
  # vault-backup.service on mgmt-vm uses for `snapshot save` — it also has
  # `snapshot-force` (restore) capability, so it covers this path too and
  # keeps the restore from depending on the operator having a personal
  # sudo-capable token handy. A manually-exported VAULT_TOKEN still wins if
  # you've set one (e.g. for a DR drill against a scoped-down test token).
  if [[ -z "${VAULT_TOKEN:-}" ]]; then
    log "VAULT_TOKEN not set — fetching vault-snapshot-token from GCP Secret Manager"
    VAULT_TOKEN=$(fetch_gcp_secret "vault-snapshot-token")
    export VAULT_TOKEN
  fi
fi

log "running: vault operator raft snapshot restore -force"
vault operator raft snapshot restore -force "$snapshot_file" \
  || die "snapshot restore failed — Vault's state is undefined at this point, do not proceed, escalate before retrying"

log "restore call succeeded — switching to the original root token for verification"
unset VAULT_TOKEN
if [[ "$FRESH_NODE" == "1" ]]; then
  ORIGINAL_ROOT_TOKEN=$(fetch_gcp_secret "vault-root-token") \
    || die "could not retrieve vault-root-token from GCP Secret Manager — this is the one bootstrap credential that must come from Secret Manager rather than Vault itself, since Vault's own keyring was just replaced"
  export VAULT_TOKEN="$ORIGINAL_ROOT_TOKEN"
else
  warn "same-node restore: re-export your original VAULT_TOKEN manually before verifying — it was unset above as a safety measure"
fi

log "verification (run manually if VAULT_TOKEN isn't re-exported yet):"
cat <<'EOF'
  vault status
  vault secrets list                       # kv/, database/ both present?
  vault auth list                          # jwt-nomad-dev, jwt-nomad-prod present?
  vault read database/creds/dev-metrics-api  # dynamic creds still issuing?
  # Then, separately, confirm Nomad can actually authenticate:
  #   nomad job status metrics-api -namespace=boutique  (per env)
EOF

log "done. Do not skip the manual verification block above — a restore that"
log "'succeeds' at the API level but has a stale JWT auth config will fail"
log "silently until the first workload tries to fetch a secret."
