#!/usr/bin/env bash
# scripts/lib/restore-common.sh
#
# Shared helpers for all restore-*.sh scripts. Not meant to be run directly —
# sourced by each restore script. Keeps the destructive scripts short and
# makes the "are you sure" / dry-run / GCS-fetch behaviour identical across
# all five.

set -euo pipefail

# Colours (disabled automatically when not a tty)
if [[ -t 1 ]]; then
  C_RED=$'\033[0;31m'; C_YEL=$'\033[0;33m'; C_GRN=$'\033[0;32m'; C_RST=$'\033[0m'
else
  C_RED=""; C_YEL=""; C_GRN=""; C_RST=""
fi

log()  { echo "${C_GRN}[restore]${C_RST} $*"; }
warn() { echo "${C_YEL}[restore]${C_RST} $*" >&2; }
die()  { echo "${C_RED}[restore] ERROR:${C_RST} $*" >&2; exit 1; }

# GCS bucket that holds all snapshot/backup artifacts (see docs/ARCHITECTURE.md
# §10 for the retention table). Overridable for testing against a scratch
# bucket.
ARTIFACTS_BUCKET="${ARTIFACTS_BUCKET:-gs://platform-artifacts}"

# --restore-common: require an explicit --env argument everywhere.
require_env() {
  local env="$1"
  case "$env" in
    dev|prod) ;;
    *) die "environment must be 'dev' or 'prod', got '${env:-<empty>}'" ;;
  esac
}

# Every restore is destructive. Refuse to proceed without an explicit,
# spelled-out confirmation unless --yes was passed (CI / documented DR drills
# only — never the default for a human running this against prod by hand).
confirm_destructive() {
  local prompt="$1"
  if [[ "${ASSUME_YES:-0}" == "1" ]]; then
    warn "ASSUME_YES set — skipping interactive confirmation"
    return 0
  fi
  echo ""
  warn "$prompt"
  read -r -p "Type the environment name (dev/prod) again to confirm: " confirm_env
  if [[ "$confirm_env" != "$TARGET_ENV" ]]; then
    die "confirmation did not match target environment ('$TARGET_ENV') — aborting, nothing was touched"
  fi
}

# Downloads the latest object under a GCS prefix, or a specific one if
# RESTORE_FILE is set (for restoring something other than "latest", e.g. a
# point-in-time DR drill or rolling back a bad restore).
fetch_latest_from_gcs() {
  local prefix="$1"      # e.g. vault-snapshots/dev/
  local dest_dir="$2"    # local scratch dir

  mkdir -p "$dest_dir"

  if [[ -n "${RESTORE_FILE:-}" ]]; then
    log "RESTORE_FILE set — fetching explicit object: $RESTORE_FILE"
    gsutil cp "${ARTIFACTS_BUCKET}/${prefix}${RESTORE_FILE}" "$dest_dir/" \
      || die "failed to fetch ${ARTIFACTS_BUCKET}/${prefix}${RESTORE_FILE}"
    echo "${dest_dir}/$(basename "$RESTORE_FILE")"
    return 0
  fi

  local latest
  latest=$(gsutil ls -l "${ARTIFACTS_BUCKET}/${prefix}" 2>/dev/null \
    | grep -v '^TOTAL:' \
    | sort -k2 \
    | tail -n1 \
    | awk '{print $NF}') || true

  [[ -n "$latest" ]] || die "no objects found under ${ARTIFACTS_BUCKET}/${prefix}"

  log "latest object: $latest"
  gsutil cp "$latest" "$dest_dir/" || die "failed to fetch $latest"
  echo "${dest_dir}/$(basename "$latest")"
}

# IAP SSH wrapper — same access pattern Ansible uses (see ansible/inventory/
# and §1.5). Avoids every script re-deriving zone/project flags.
GCP_PROJECT="${GCP_PROJECT:?set GCP_PROJECT before running any restore script}"
GCP_ZONE="${GCP_ZONE:-us-central1-a}"

iap_ssh() {
  local instance="$1"; shift
  gcloud compute ssh "$instance" \
    --project="$GCP_PROJECT" \
    --zone="$GCP_ZONE" \
    --tunnel-through-iap \
    --command "$*"
}

iap_scp_to() {
  local local_path="$1" instance="$2" remote_path="$3"
  gcloud compute scp "$local_path" "${instance}:${remote_path}" \
    --project="$GCP_PROJECT" \
    --zone="$GCP_ZONE" \
    --tunnel-through-iap
}

# Vault, Nomad, and Postgres are only reachable from outside the VPC through
# traefik-internal's *.platform.lefrancis.org routes — platform.lefrancis.org
# is a private Cloud DNS zone and traefik-internal has no public IP. This
# does a cheap TCP-level check before any of those scripts try to actually
# use the connection, so a missing tunnel fails fast with the exact fix
# instead of surfacing as a confusing timeout three steps into a restore.
# Scripts that IAP-SSH directly onto a VM and run their restore command
# locally (restore-consul.sh, restore-octopus.sh) never call this — they
# never leave the private network via traefik-internal in the first place.
preflight_traefik_route() {
  local hostname="$1"
  local port="${2:-443}"

  if timeout 3 bash -c "echo > /dev/tcp/${hostname}/${port}" 2>/dev/null; then
    return 0
  fi

  cat >&2 <<EOF
${C_RED}[restore] ERROR:${C_RST} cannot reach ${hostname}:${port}.

platform.lefrancis.org is a private Cloud DNS zone and traefik-internal has
no public IP — this hostname will not resolve or connect from outside the
VPC without an IAP tunnel into traefik-internal ITSELF (not the backend
service's own VM). Set this up in a separate terminal, then re-run this
script:

  gcloud compute start-iap-tunnel traefik-internal ${port} \\
    --local-host-port=localhost:${port} \\
    --project=\$GCP_PROJECT --zone=\$GCP_ZONE

  # then, so TLS SNI / cert matching still resolve the right vhost through
  # the tunnel:
  echo "127.0.0.1 ${hostname}" | sudo tee -a /etc/hosts

If you're already running this from inside the VPC (e.g. from a box on one
of the private subnets), this check can be skipped by exporting
SKIP_TRAEFIK_PREFLIGHT=1 instead.
EOF
  [[ "${SKIP_TRAEFIK_PREFLIGHT:-0}" == "1" ]] && { warn "SKIP_TRAEFIK_PREFLIGHT=1 — proceeding without the reachability check"; return 0; }
  exit 1
}

SCRATCH_DIR="$(mktemp -d /tmp/restore.XXXXXX)"
trap 'rm -rf "$SCRATCH_DIR"' EXIT
