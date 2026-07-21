#!/bin/bash
# generate-and-push-pki.sh
#
# Standalone script for generating PKI artifacts
# Run this from your host machine whenever you need to bootstrap PKI for the first time,
# or to ROTATE everything later (just re-run it). It always regenerates the full tree
# and pushes fresh versions to Secret Manager — there's no "skip if exists" here, since
# regenerating is the whole point of rotation. Rotating the CA invalidates
# every leaf cert anyway, so there's no meaningful way to rotate "just one
# leaf" without also touching the rest — this script embraces that and
# always does the whole tree in one pass.
#
# Every certificate/key generated here is pushed to Secret Manager. No
# local copy is kept once the script finishes (temp dir is wiped) —
# every VM/role fetches directly from Secret Manager during its own
# Ansible run, rather than anything being distributed by Ansible from a
# local file.
#
# Requires: openssl, gcloud (authenticated, with Secret Manager write
# access), and every secret container below already created in
# terraform/bootstrap's default_secrets map (this script only writes
# versions, never creates containers).
#
# Usage: ./generate-and-push-pki.sh <gcp-project-id>

set -euo pipefail

PROJECT_ID="${1:?Usage: $0 <gcp-project-id>}"

# --- Pre-Flight: Every Secret Container Below Must Already Exist In
# terraform/bootstrap's default_secrets Map (Created There So They Share
# The Same storage_cmek KMS Key And Replication/Labeling As Everything
# Else) — This Script Only ADDS VERSIONS, It Never Creates Containers.
# Failing Fast Here With A Clear List Beats A Raw gcloud NOT_FOUND Error
# Halfway Through A Run.
REQUIRED_SECRETS=(
  ca-cert-dev
  ca-key-dev
  ca-cert-prod
  ca-key-prod
  management-ca-cert
  management-ca-key
  consul-server-cert-dev
  consul-server-tls-key-dev
  consul-server-cert-prod
  consul-server-tls-key-prod
  consul-client-cert-dev
  consul-client-tls-key-dev
  consul-client-cert-prod
  consul-client-tls-key-prod
  nomad-server-cert-dev
  nomad-server-tls-key-dev
  nomad-server-cert-prod
  nomad-server-tls-key-prod
  nomad-client-cert-dev
  nomad-client-tls-key-dev
  nomad-client-cert-prod
  nomad-client-tls-key-prod
  nomad-gossip-key-dev
  nomad-gossip-key-prod
  consul-gossip-key-dev
  consul-gossip-key-prod
  vault-cert
  vault-tls-key
  consul-traefik-token-dev
  consul-traefik-token-prod
)

echo "Checking all required secret containers exist in project ${PROJECT_ID}..."
MISSING=()
for s in "${REQUIRED_SECRETS[@]}"; do
  if ! gcloud secrets describe "${s}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
    MISSING+=("${s}")
  fi
done

if [ "${#MISSING[@]}" -gt 0 ]; then
  echo "ERROR: The following secret containers don't exist yet:"
  printf '  - %s\n' "${MISSING[@]}"
  echo "Add these to terraform/bootstrap's default_secrets map and apply before running this script."
  exit 1
fi
echo "All secret containers present. Proceeding."

WORKDIR="$(mktemp -d)"
trap 'rm -rf "${WORKDIR}"' EXIT

echo "Working in ${WORKDIR} (wiped on exit, nothing persists locally)"

push_secret() {
  local secret_name="$1"
  local file_path="$2"
  echo "  -> pushing ${secret_name}"
  gcloud secrets versions add "${secret_name}" \
    --data-file="${file_path}" --project="${PROJECT_ID}" >/dev/null
}

generate_ca() {
  local name="$1"       # e.g. "dev", "prod", or "management"
  local cn="$2"
  echo "Generating ${name} CA..."
  openssl req -x509 -newkey rsa:4096 -nodes -sha256 -days 3650 \
    -keyout "${WORKDIR}/${name}-ca-key.pem" \
    -out "${WORKDIR}/${name}-ca-cert.pem" \
    -subj "/CN=${cn}" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign,cRLSign"
}

# Generates a leaf cert signed by the given CA, with a proper SAN list.
generate_leaf() {
  local out_prefix="$1"        # e.g. "consul-server-dev"
  local common_name="$2"       # e.g. "server.dc-dev.consul"
  local san_list="$3"          # e.g. "DNS:server.dc-dev.consul,DNS:localhost,IP:127.0.0.1"
  local ca_cert="$4"
  local ca_key="$5"

  openssl req -newkey rsa:4096 -nodes -sha256 \
    -keyout "${WORKDIR}/${out_prefix}-key.pem" \
    -out "${WORKDIR}/${out_prefix}-csr.pem" \
    -subj "/CN=${common_name}"

  cat > "${WORKDIR}/${out_prefix}-ext.cnf" <<EOF
subjectAltName = ${san_list}
extendedKeyUsage = serverAuth, clientAuth
EOF

  openssl x509 -req -sha256 -days 825 \
    -in "${WORKDIR}/${out_prefix}-csr.pem" \
    -CA "${ca_cert}" -CAkey "${ca_key}" -CAcreateserial \
    -extfile "${WORKDIR}/${out_prefix}-ext.cnf" \
    -out "${WORKDIR}/${out_prefix}-cert.pem"
}

# --- Environment-Specific CAs (Dev & Prod) ---
generate_ca dev "Dev Environment CA - nomad-platform-gcp"
push_secret ca-cert-dev "${WORKDIR}/dev-ca-cert.pem"
push_secret ca-key-dev  "${WORKDIR}/dev-ca-key.pem"

generate_ca prod "Prod Environment CA - nomad-platform-gcp"
push_secret ca-cert-prod "${WORKDIR}/prod-ca-cert.pem"
push_secret ca-key-prod  "${WORKDIR}/prod-ca-key.pem"

# --- Management CA (For Vault, Shared Across Both Environments) ---
generate_ca management "Management CA - nomad-platform-gcp"
push_secret management-ca-cert "${WORKDIR}/management-ca-cert.pem"
push_secret management-ca-key  "${WORKDIR}/management-ca-key.pem"

# --- Consul Server/Client Certs, Per Environment ---
for env in dev prod; do
  # Map internal env name to file prefix
  ca_file_prefix="${env}"
  if [ "${env}" = "dev" ] || [ "${env}" = "prod" ]; then
    ca_file_prefix="${env}"
  fi

  generate_leaf "consul-server-${env}" "server.dc-${env}.consul" \
    "DNS:server.dc-${env}.consul,DNS:localhost,IP:127.0.0.1" \
    "${WORKDIR}/${ca_file_prefix}-ca-cert.pem" "${WORKDIR}/${ca_file_prefix}-ca-key.pem"
  push_secret "consul-server-cert-${env}" "${WORKDIR}/consul-server-${env}-cert.pem"
  push_secret "consul-server-tls-key-${env}" "${WORKDIR}/consul-server-${env}-key.pem"

  generate_leaf "consul-client-${env}" "client.dc-${env}.consul" \
    "DNS:client.dc-${env}.consul,DNS:localhost,IP:127.0.0.1" \
    "${WORKDIR}/${ca_file_prefix}-ca-cert.pem" "${WORKDIR}/${ca_file_prefix}-ca-key.pem"
  push_secret "consul-client-cert-${env}" "${WORKDIR}/consul-client-${env}-cert.pem"
  push_secret "consul-client-tls-key-${env}" "${WORKDIR}/consul-client-${env}-key.pem"
done

# --- Nomad Server/Client Certs, Per Environment ---
for env in dev prod; do
  generate_leaf "nomad-server-${env}" "server.dc-${env}.nomad" \
    "DNS:server.dc-${env}.nomad,DNS:localhost,IP:127.0.0.1" \
    "${WORKDIR}/${env}-ca-cert.pem" "${WORKDIR}/${env}-ca-key.pem"
  push_secret "nomad-server-cert-${env}" "${WORKDIR}/nomad-server-${env}-cert.pem"
  push_secret "nomad-server-tls-key-${env}" "${WORKDIR}/nomad-server-${env}-key.pem"

  generate_leaf "nomad-client-${env}" "client.dc-${env}.nomad" \
    "DNS:client.dc-${env}.nomad,DNS:localhost,IP:127.0.0.1" \
    "${WORKDIR}/${env}-ca-cert.pem" "${WORKDIR}/${env}-ca-key.pem"
  push_secret "nomad-client-cert-${env}" "${WORKDIR}/nomad-client-${env}-cert.pem"
  push_secret "nomad-client-tls-key-${env}" "${WORKDIR}/nomad-client-${env}-key.pem"
done

# --- Vault's Cert & Key (Signed by Management CA) ---
generate_leaf vault "vault.platform.lefrancis.org" \
  "DNS:vault.platform.lefrancis.org,DNS:localhost,IP:127.0.0.1" \
  "${WORKDIR}/management-ca-cert.pem" "${WORKDIR}/management-ca-key.pem"
push_secret vault-cert "${WORKDIR}/vault-cert.pem"
push_secret vault-tls-key "${WORKDIR}/vault-key.pem"

# --- Consul & Nomad Gossip Encryption Keys, Per Environment ---
for env in dev prod; do
  openssl rand -base64 32 > "${WORKDIR}/consul-gossip-key-${env}.txt"
  push_secret "consul-gossip-key-${env}" "${WORKDIR}/consul-gossip-key-${env}.txt"

  openssl rand -base64 32 > "${WORKDIR}/nomad-gossip-key-${env}.txt"
  push_secret "nomad-gossip-key-${env}" "${WORKDIR}/nomad-gossip-key-${env}.txt"
done

# --- Consul Traefik Tokens, Per Environment ---
for env in dev prod; do
  openssl rand -hex 16 > "${WORKDIR}/consul-traefik-token-${env}.txt"
  push_secret "consul-traefik-token-${env}" "${WORKDIR}/consul-traefik-token-${env}.txt"
done

echo "Done. Everything pushed to Secret Manager; nothing kept locally."