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
#     A brand-new Raft store has no data and no keyring, so there is nothing
#     for a token to authenticate against yet. `vault operator init` bootstraps
#     a THROWAWAY keyring + root token good for exactly one thing: making the
#     authenticated restore call. The instant the restore succeeds, that
#     throwaway keyring is discarded and replaced by the snapshot's own
#     keyring — the throwaway token stops working. All post-restore
#     verification must switch to the ORIGINAL root token, which per §1.4 is
#     the one artifact GCP Secret Manager holds for bootstrap purposes
#     (`vault-root-token`). This is the one credential that cannot come from
#     Vault itself, because Vault isn't up yet — hence Secret Manager, not KV.
#
# Usage:
#   GCP_PROJECT=my-project scripts/restore-vault.sh --env dev [--fresh-node]
#
#   --fresh-node   This is a full node rebuild (Scenario 2 above). Without
#                  this flag the script assumes Scenario 1 (same node,
#                  already unsealed) and will refuse to run `operator init`.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=lib/restore-common.sh
source lib/restore-common.sh

TARGET_ENV=""
FRESH_NODE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --env) TARGET_ENV="$2"; shift 2 ;;
    --fresh-node) FRESH_NODE=1; shift ;;
    --yes) ASSUME_YES=1; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done
require_env "$TARGET_ENV"

# Vault is single-instance on mgmt-vm and serves both environments — "env"
# here only selects which snapshot prefix to pull from, not a different
# target host. Restoring dev's snapshot restores the WHOLE Vault instance,
# including prod's secrets engines and policies. Make that unambiguous.
if [[ "$TARGET_ENV" == "dev" || "$TARGET_ENV" == "prod" ]]; then
  warn "Vault is a single shared instance on mgmt-vm — restoring ANY snapshot"
  warn "restores secrets engines and policies for BOTH dev and prod, not just"
  warn "the environment named below. The --env flag only selects which"
  warn "snapshot prefix to pull the backup file from."
fi

VAULT_ADDR="${VAULT_ADDR:-https://vault.platform.lefrancis.org}"
export VAULT_ADDR

# Reachability: vault.platform.lefrancis.org is a private Cloud DNS hostname,
# only reachable through traefik-internal (no public IP on that VM). Needs
# an IAP tunnel into traefik-internal ITSELF before this script can reach it
# — preflight_traefik_route prints the exact tunnel command if it isn't set
# up yet.
log "checking route to vault.platform.lefrancis.org via traefik-internal"
preflight_traefik_route "vault.platform.lefrancis.org" 443

confirm_destructive "About to OVERWRITE the live Vault instance (mgmt-vm) with a Raft snapshot. This replaces ALL secrets engines, policies, auth methods, and the encryption keyring for both dev and prod."

snapshot_file=$(fetch_latest_from_gcs "vault-snapshots/" "$SCRATCH_DIR")
log "using snapshot: $snapshot_file"

if [[ "$FRESH_NODE" == "1" ]]; then
  log "fresh-node mode: bootstrapping a throwaway keyring to authenticate the restore call"
  # GCP KMS auto-unseal means no unseal keys are returned here — only
  # recovery keys, which we discard. We only need the root token, and only
  # for the few seconds it takes to issue the restore call.
  init_output=$(vault operator init -format=json -recovery-shares=1 -recovery-threshold=1) \
    || die "vault operator init failed — check the gcpckms seal stanza was applied by Ansible before running this script"
  throwaway_root_token=$(echo "$init_output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["root_token"])')
  export VAULT_TOKEN="$throwaway_root_token"
  log "throwaway root token acquired (will be invalidated automatically by the restore below)"
else
  [[ -n "${VAULT_TOKEN:-}" ]] || die "VAULT_TOKEN not set — export a sudo-capable token for the already-running Vault instance, or pass --fresh-node if this is a full node rebuild"
fi

log "running: vault operator raft snapshot restore -force"
vault operator raft snapshot restore -force "$snapshot_file" \
  || die "snapshot restore failed — Vault's state is undefined at this point, do not proceed, escalate before retrying"

log "restore call succeeded — switching to the original root token for verification"
unset VAULT_TOKEN
if [[ "$FRESH_NODE" == "1" ]]; then
  ORIGINAL_ROOT_TOKEN=$(gcloud secrets versions access latest \
    --secret="vault-root-token" --project="$GCP_PROJECT") \
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
