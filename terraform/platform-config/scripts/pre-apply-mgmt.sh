#!/bin/bash
# scripts/pre-apply-mgmt.sh
#
# Exports what mgmt/ needs: VAULT_TOKEN (Vault's own env var, no
# aliasing needed — single instance) plus Octopus's API key as
# TF_VAR_octopus_api_key.
#
# No VAULT_CACERT any more: the vault provider now reaches Vault
# through traefik-internal (scripts/open-tunnel.sh mgmt), which
# terminates TLS with a real Let's Encrypt certificate — the system
# trust store is enough, same reasoning as scripts/pre-apply-env.sh.
#
# MUST be sourced: source ./scripts/pre-apply-mgmt.sh <gcp-project-id>

set -uo pipefail
PROJECT_ID="${1:?Usage: source ./pre-apply-mgmt.sh <gcp-project-id>}"

export VAULT_TOKEN="$(gcloud secrets versions access latest --secret=vault-operator-token --project="${PROJECT_ID}")"
export TF_VAR_octopus_api_key="$(gcloud secrets versions access latest --secret=octopus-admin-api-key --project="${PROJECT_ID}")"

echo "pre-apply-mgmt: tokens exported for this shell."
echo "First time on this machine? Run scripts/update-hosts.sh once."
echo "Open the mgmt tunnel with: scripts/open-tunnel.sh mgmt <project> <zone>"
