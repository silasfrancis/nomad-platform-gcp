#!/bin/bash
# scripts/pre-apply-mgmt.sh
#
# Exports what mgmt/ needs: VAULT_TOKEN/VAULT_CACERT (Vault's own env
# vars, no aliasing needed — single instance) plus Octopus's API key as
# TF_VAR_octopus_api_key. Nothing written to disk except the CA cert,
# wiped on shell exit.
#
# MUST be sourced: source ./scripts/pre-apply-mgmt.sh <gcp-project-id>

set -uo pipefail
PROJECT_ID="${1:?Usage: source ./pre-apply-mgmt.sh <gcp-project-id>}"

_PA_TMP_CA_DIR="$(mktemp -d)"
cleanup_pre_apply_mgmt() {
  rm -rf "${_PA_TMP_CA_DIR}"
  echo "pre-apply-mgmt: CA cert temp file wiped."
}
trap cleanup_pre_apply_mgmt EXIT

export VAULT_TOKEN="$(gcloud secrets versions access latest --secret=vault-operator-token --project="${PROJECT_ID}")"
gcloud secrets versions access latest --secret=management-ca-cert --project="${PROJECT_ID}" > "${_PA_TMP_CA_DIR}/management-ca-cert.pem"
export VAULT_CACERT="${_PA_TMP_CA_DIR}/management-ca-cert.pem"

export TF_VAR_octopus_api_key="$(gcloud secrets versions access latest --secret=octopus-admin-api-key --project="${PROJECT_ID}")"

echo "pre-apply-mgmt: tokens + CA cert exported. Vault's cert supports"
echo "localhost/127.0.0.1 directly (see PKI script SAN lists) — open"
echo "the mgmt tunnel with: scripts/open-tunnel.sh mgmt <project> <zone>"
