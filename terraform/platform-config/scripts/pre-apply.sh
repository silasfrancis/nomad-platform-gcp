#!/bin/bash
# scripts/pre-apply.sh
#
# Fetches every operator token + CA cert this platform-config's four
# root modules (vault/, consul/, nomad/, octopus/) need, and exports
# them as VAULT_*/TF_VAR_* environment variables. Nothing is written to
# disk except two CA cert files — vault/consul/nomad's TLS options need
# a real file path, not inline PEM content — wiped automatically on
# shell exit via the trap below.
#
# MUST be sourced, not executed:
#   source ./scripts/pre-apply.sh <gcp-project-id>
# Running it as ./pre-apply.sh exports into a subshell that exits
# immediately, leaving your actual shell with nothing set.
#
# Tunnels (open-tunnels.sh) must already be running before this is
# sourced and before any `terraform apply` in consul/ or nomad/ — both
# aliased providers dial localhost:18500/18501/14646/14647.

set -uo pipefail # not -e: a sourced script shouldn't kill the caller's shell on error

PROJECT_ID="${1:?Usage: source ./pre-apply.sh <gcp-project-id>}"

_PA_TMP_CA_DIR="$(mktemp -d)"

cleanup_pre_apply() {
  rm -rf "${_PA_TMP_CA_DIR}"
  echo "pre-apply: CA cert temp files wiped."
}
trap cleanup_pre_apply EXIT

# --- Vault (single provider, no aliasing — plain env vars work) ---
export VAULT_TOKEN="$(gcloud secrets versions access latest --secret=vault-operator-token --project="${PROJECT_ID}")"
gcloud secrets versions access latest --secret=management-ca-cert --project="${PROJECT_ID}" > "${_PA_TMP_CA_DIR}/management-ca-cert.pem"
export VAULT_CACERT="${_PA_TMP_CA_DIR}/management-ca-cert.pem"

# --- Consul (aliased dev/prod — exported as TF_VAR_*, since a single
# CONSUL_HTTP_TOKEN env var can't hold two different per-alias tokens) ---
export TF_VAR_consul_token_dev="$(gcloud secrets versions access latest --secret=consul-operator-token-dev --project="${PROJECT_ID}")"
export TF_VAR_consul_token_prod="$(gcloud secrets versions access latest --secret=consul-operator-token-prod --project="${PROJECT_ID}")"
gcloud secrets versions access latest --secret=ca-cert-dev --project="${PROJECT_ID}" > "${_PA_TMP_CA_DIR}/ca-cert-dev.pem"
gcloud secrets versions access latest --secret=ca-cert-prod --project="${PROJECT_ID}" > "${_PA_TMP_CA_DIR}/ca-cert-prod.pem"
export TF_VAR_consul_cacert_dev="${_PA_TMP_CA_DIR}/ca-cert-dev.pem"
export TF_VAR_consul_cacert_prod="${_PA_TMP_CA_DIR}/ca-cert-prod.pem"

# --- Nomad (aliased dev/prod, same reasoning as Consul; reuses the same
# per-env CA files since Consul and Nomad share one CA per environment
# under the 3-CA-by-environment PKI redesign) ---
export TF_VAR_nomad_token_dev="$(gcloud secrets versions access latest --secret=nomad-operator-token-dev --project="${PROJECT_ID}")"
export TF_VAR_nomad_token_prod="$(gcloud secrets versions access latest --secret=nomad-operator-token-prod --project="${PROJECT_ID}")"
export TF_VAR_nomad_cacert_dev="${_PA_TMP_CA_DIR}/ca-cert-dev.pem"
export TF_VAR_nomad_cacert_prod="${_PA_TMP_CA_DIR}/ca-cert-prod.pem"

# --- Octopus ---
export TF_VAR_octopus_api_key="$(gcloud secrets versions access latest --secret=octopus-admin-api-key --project="${PROJECT_ID}")"

echo "pre-apply: tokens + CA certs exported for this shell session."
echo "Remember: tunnels (open-tunnels.sh) must already be open before applying consul/ or nomad/."
