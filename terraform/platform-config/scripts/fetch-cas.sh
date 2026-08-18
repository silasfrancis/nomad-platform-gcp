#!/bin/bash

# scripts/fetch-cas.sh
#
# Pulls the CA public certs out of Secret Manager and stores them 
# centrally in ~/.terraform-certs so they stay completely outside 
# the project directory.

set -euo pipefail

: "${GCP_PROJECT_ID:?Set GCP_PROJECT_ID before running this script}"

# Store globally in the user home directory (~/.terraform-certs)
CERTS_DIR="${HOME}/.terraform-certs"
mkdir -p "${CERTS_DIR}"

declare -A CA_SECRETS=(
  ["management-ca-cert"]="management-ca.pem"
  ["ca-cert-dev"]="ca-dev.pem"
  ["ca-cert-prod"]="ca-prod.pem"
)

for secret_id in "${!CA_SECRETS[@]}"; do
  out_file="${CERTS_DIR}/${CA_SECRETS[$secret_id]}"
  echo "Fetching ${secret_id} → ${out_file}"
  gcloud secrets versions access latest \
    --secret="${secret_id}" \
    --project="${GCP_PROJECT_ID}" \
    > "${out_file}"
done

echo
echo "Done. CA certs written to ${CERTS_DIR}/"
echo "Reference them in provider blocks using absolute paths, e.g.:"
echo '  ca_cert_file =pathexpand("~/.terraform-certs/management-ca.pem")'