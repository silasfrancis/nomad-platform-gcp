#!/bin/bash
# scripts/pre-apply-env.sh
#
# Exports what dev/ or prod/ needs for ONE environment only — never
# both at once, matching the directory-per-environment structure. No
# aliasing, so plain TF_VAR_consul_token/TF_VAR_nomad_token (not the
# _dev/_prod-suffixed names from the earlier combined-apply design).
#
# MUST be sourced: source ./scripts/pre-apply-env.sh <gcp-project-id> <dev|prod>

set -uo pipefail
PROJECT_ID="${1:?Usage: source ./pre-apply-env.sh <gcp-project-id> <dev|prod>}"
ENVIRONMENT="${2:?Usage: source ./pre-apply-env.sh <gcp-project-id> <dev|prod>}"

if [[ "${ENVIRONMENT}" != "dev" && "${ENVIRONMENT}" != "prod" ]]; then
  echo "ERROR: environment must be 'dev' or 'prod', got '${ENVIRONMENT}'" >&2
  return 1 2>/dev/null || exit 1
fi

_PA_TMP_CA_DIR="$(mktemp -d)"
cleanup_pre_apply_env() {
  rm -rf "${_PA_TMP_CA_DIR}"
  echo "pre-apply-env: CA cert temp file wiped."
}
trap cleanup_pre_apply_env EXIT

export TF_VAR_consul_token="$(gcloud secrets versions access latest --secret=consul-operator-token-${ENVIRONMENT} --project="${PROJECT_ID}")"
export TF_VAR_nomad_token="$(gcloud secrets versions access latest --secret=nomad-operator-token-${ENVIRONMENT} --project="${PROJECT_ID}")"

gcloud secrets versions access latest --secret=ca-cert-${ENVIRONMENT} --project="${PROJECT_ID}" > "${_PA_TMP_CA_DIR}/ca-cert-${ENVIRONMENT}.pem"
export TF_VAR_consul_cacert="${_PA_TMP_CA_DIR}/ca-cert-${ENVIRONMENT}.pem"
export TF_VAR_nomad_cacert="${_PA_TMP_CA_DIR}/ca-cert-${ENVIRONMENT}.pem"

echo "pre-apply-env: ${ENVIRONMENT} tokens + CA cert exported for this shell."
echo "Open only ${ENVIRONMENT}'s tunnel before applying: scripts/open-tunnel.sh ${ENVIRONMENT} <project> <zone>"
