#!/bin/bash
# generate-and-push-pki.sh
#
# Standalone script (not Ansible) — run this from your laptop whenever you
# need to bootstrap PKI for the first time, or to ROTATE everything later
# (just re-run it). It always regenerates the full tree and pushes fresh
# versions to Secret Manager — there's no "skip if exists" here, since
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
  local name="$1"      # "consul" or "nomad"
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

# --- Consul CA ---
generate_ca consul "Consul CA - nomad-platform-gcp"
push_secret consul-ca-cert "${WORKDIR}/consul-ca-cert.pem"
push_secret consul-ca-key  "${WORKDIR}/consul-ca-key.pem"

# --- Nomad CA ---
generate_ca nomad "Nomad CA - nomad-platform-gcp"
push_secret nomad-ca-cert "${WORKDIR}/nomad-ca-cert.pem"
push_secret nomad-ca-key  "${WORKDIR}/nomad-ca-key.pem"

# --- Consul Server/Client Certs, Per Environment ---
for env in dev prod; do
  generate_leaf "consul-server-${env}" "server.dc-${env}.consul" \
    "DNS:server.dc-${env}.consul,DNS:localhost,IP:127.0.0.1" \
    "${WORKDIR}/consul-ca-cert.pem" "${WORKDIR}/consul-ca-key.pem"
  push_secret "consul-server-cert-${env}" "${WORKDIR}/consul-server-${env}-cert.pem"
  push_secret "consul-server-key-${env}"  "${WORKDIR}/consul-server-${env}-key.pem"

  generate_leaf "consul-client-${env}" "client.dc-${env}.consul" \
    "DNS:client.dc-${env}.consul,DNS:localhost,IP:127.0.0.1" \
    "${WORKDIR}/consul-ca-cert.pem" "${WORKDIR}/consul-ca-key.pem"
  push_secret "consul-client-cert-${env}" "${WORKDIR}/consul-client-${env}-cert.pem"
  push_secret "consul-client-key-${env}"  "${WORKDIR}/consul-client-${env}-key.pem"
done

# --- Nomad Server/Client Certs, Shared Across Both Environments ---
# region = "global" — Dev And Prod Are Two Fully Isolated Clusters That
# Never Federate, So One Cert Pair Covers Both.
generate_leaf nomad-server "server.global.nomad" \
  "DNS:server.global.nomad,DNS:localhost,IP:127.0.0.1" \
  "${WORKDIR}/nomad-ca-cert.pem" "${WORKDIR}/nomad-ca-key.pem"
push_secret nomad-server-cert "${WORKDIR}/nomad-server-cert.pem"
push_secret nomad-server-key  "${WORKDIR}/nomad-server-key.pem"

generate_leaf nomad-client "client.global.nomad" \
  "DNS:client.global.nomad,DNS:localhost,IP:127.0.0.1" \
  "${WORKDIR}/nomad-ca-cert.pem" "${WORKDIR}/nomad-ca-key.pem"
push_secret nomad-client-cert "${WORKDIR}/nomad-client-cert.pem"
push_secret nomad-client-key  "${WORKDIR}/nomad-client-key.pem"

# --- Vault's Cert (Self-Signed — No CA Chain, Same As Before) ---
# Not Signed By Either CA Above — Vault Is A Standalone Singleton, Its
# Cert Only Needs To Be Its Own Trust Anchor For Whoever Connects To It.
openssl req -x509 -newkey rsa:4096 -nodes -sha256 -days 825 \
  -keyout "${WORKDIR}/vault-key.pem" \
  -out "${WORKDIR}/vault-cert.pem" \
  -subj "/CN=vault.platform.lefrancis.org" \
  -addext "subjectAltName=DNS:vault.platform.lefrancis.org,DNS:localhost,IP:127.0.0.1"
push_secret vault-cert "${WORKDIR}/vault-cert.pem"
push_secret vault-key  "${WORKDIR}/vault-key.pem"

# --- Consul Gossip Encryption Keys, Per Environment ---
# Kept Separate Per Env So A Compromise Of Dev's Key Doesn't Expose Prod's
# Gossip Traffic.
for env in dev prod; do
  openssl rand -base64 32 > "${WORKDIR}/consul-gossip-key-${env}.txt"
  push_secret "consul-gossip-key-${env}" "${WORKDIR}/consul-gossip-key-${env}.txt"
done

echo "Done. Everything pushed to Secret Manager; nothing kept locally."