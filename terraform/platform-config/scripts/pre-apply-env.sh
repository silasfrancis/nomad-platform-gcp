#!/bin/bash
# scripts/pre-apply-env.sh
#
# Exports what dev/ or prod/ needs for ONE environment only — never
# both at once, matching the directory-per-environment structure. No
# aliasing, so plain TF_VAR_consul_token/TF_VAR_nomad_token (not the
# _dev/_prod-suffixed names from the earlier combined-apply design).
#
# No CA cert to fetch or wipe any more: both providers now go through
# traefik-internal (scripts/open-tunnel.sh), which terminates TLS with
# a real Let's Encrypt certificate — the system trust store is enough.
#
# MUST be sourced: source ./scripts/pre-apply-env.sh <gcp-project-id> <dev|prod>

set -uo pipefail
PROJECT_ID="${1:?Usage: source ./pre-apply-env.sh <gcp-project-id> <dev|prod>}"
ENVIRONMENT="${2:?Usage: source ./pre-apply-env.sh <gcp-project-id> <dev|prod>}"

if [[ "${ENVIRONMENT}" != "dev" && "${ENVIRONMENT}" != "prod" ]]; then
  echo "ERROR: environment must be 'dev' or 'prod', got '${ENVIRONMENT}'" >&2
  return 1 2>/dev/null || exit 1
fi

export TF_VAR_consul_token="$(gcloud secrets versions access latest --secret=consul-operator-token-${ENVIRONMENT} --project="${PROJECT_ID}")"
export TF_VAR_nomad_token="$(gcloud secrets versions access latest --secret=nomad-operator-token-${ENVIRONMENT} --project="${PROJECT_ID}")"

echo "pre-apply-env: ${ENVIRONMENT} tokens exported for this shell."
echo "First time on this machine? Run scripts/update-hosts.sh once."
echo "Open only ${ENVIRONMENT}'s tunnel before applying: scripts/open-tunnel.sh ${ENVIRONMENT} <project> <zone>"
