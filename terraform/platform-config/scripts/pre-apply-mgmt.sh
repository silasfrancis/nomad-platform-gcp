#!/bin/bash
# scripts/pre-apply-mgmt.sh
#
# Exports what mgmt/ needs: TF_VAR_vault_token plus Octopus's API key as
# TF_VAR_octopus_api_key.
#
# MUST be sourced: source ./scripts/pre-apply-mgmt.sh <gcp-project-id>

set -uo pipefail
PROJECT_ID="${1:?Usage: source ./pre-apply-mgmt.sh <gcp-project-id>}"

export TF_VAR_vault_token="$(gcloud secrets versions access latest --secret=vault-operator-token --project="${PROJECT_ID}")"
export TF_VAR_octopus_api_key="$(gcloud secrets versions access latest --secret=octopus-admin-api-key --project="${PROJECT_ID}")"

echo "pre-apply-mgmt: tokens exported for this shell."
echo "First time on this machine? Run scripts/update-hosts.sh once."
echo "Open the mgmt tunnel with: scripts/open-tunnel.sh mgmt <project> <zone>"
