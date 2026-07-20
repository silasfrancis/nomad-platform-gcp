#!/bin/bash
# GCE Startup Script — nomad-server Static Instances Only (Both dev And
# prod, Terraform Passes The Right Metadata Per-Instance).
#
# Ansible's Job (mgmt.yml/nomad-servers.yml): Install Binaries, Create
# Users/Directories, Template The Systemd Units, Enable (NOT Start) The
# Services. Everything Instance-Specific Or Secret Lives Here Instead —
# Same Split As nomad-client-startup.sh, Applied To The Static Server
# VMs Too, For One Consistent Mental Model Across Both Node Types Rather
# Than Two Different Patterns.
#
# Runs On Every Boot — Idempotent By Design, Same As The Client Script.
# This Also Means Secrets/Certs/Tokens Get Re-Fetched Fresh On Every
# Reboot (Patching, Maintenance, Host Migration) Rather Than Staying
# Stuck At Whatever Was Present During The Original Ansible Run — A
# Rotated Token Or Cert Is Picked Up Automatically On The Next Restart,
# No Manual Ansible Re-Run Needed.

set -euo pipefail

METADATA_URL="http://metadata.google.internal/computeMetadata/v1/instance"
METADATA_HEADER="Metadata-Flavor: Google"

get_metadata() {
  curl -sf -H "${METADATA_HEADER}" "${METADATA_URL}/attributes/$1"
}

# --- Values Supplied By Terraform Via Instance Metadata ---
ENVIRONMENT="$(get_metadata env)"                 # "dev" or "prod"
DATACENTER="$(get_metadata datacenter)"           # "dc-dev" or "dc-prod"
BOOTSTRAP_EXPECT="$(get_metadata bootstrap_expect)"  # "1" (dev) or "3" (prod)
RETRY_JOIN_CSV="$(get_metadata retry_join)"       # comma-separated server names, same env

PRIVATE_IP="$(curl -sf -H "${METADATA_HEADER}" \
  "${METADATA_URL}/network-interfaces/0/ip")"

NODE_NAME="$(hostname)"

GCP_PROJECT="$(curl -sf -H "${METADATA_HEADER}" \
  "http://metadata.google.internal/computeMetadata/v1/project/project-id")"

ACCESS_TOKEN="$(curl -sf -H "${METADATA_HEADER}" \
  "${METADATA_URL}/service-accounts/default/token" | \
  grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)"

fetch_secret() {
  local secret_name="$1"
  curl -sf \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    "https://secretmanager.googleapis.com/v1/projects/${GCP_PROJECT}/secrets/${secret_name}/versions/latest:access" \
    | grep -o '"data":"[^"]*"' | cut -d'"' -f4 | base64 -d
}

# --- Fetch Everything From Secret Manager ---
# Consul: CA + Server Leaf Cert/Key Are Per-Environment (Consul's
# Hostname Verification Requires It). Consul Agent Token Is Minted By
# terraform/platform-config AFTER Bootstrap — Fetch And Apply It Here
# Too, So A Reboot After Rotation Picks Up The Current One Automatically.
mkdir -p /etc/consul.d/tls
fetch_secret "consul-ca-cert" > /etc/consul.d/tls/ca.pem
fetch_secret "consul-server-cert-${ENVIRONMENT}" > /etc/consul.d/tls/cert.pem
fetch_secret "consul-server-key-${ENVIRONMENT}" > /etc/consul.d/tls/key.pem
chown consul:consul /etc/consul.d/tls/ca.pem /etc/consul.d/tls/cert.pem /etc/consul.d/tls/key.pem
chmod 0644 /etc/consul.d/tls/ca.pem /etc/consul.d/tls/cert.pem
chmod 0600 /etc/consul.d/tls/key.pem

CONSUL_GOSSIP_KEY="$(fetch_secret "consul-gossip-key-${ENVIRONMENT}")"

# consul-server-token-{env} — Created By platform-config's consul-acl.tf
# Once Flag 4 (agent-policy Restructuring) Is Resolved And Built. Fetched
# Here, But Only Applied After Consul Starts (See Below) Since
# `set-agent-token` Needs A Running Agent To Talk To.
CONSUL_SERVER_TOKEN="$(fetch_secret "consul-server-token-${ENVIRONMENT}" || echo "")"

# Nomad: CA + Server Leaf Cert/Key Are Shared, Not Per-Environment (Dev/
# Prod Never Federate — See scripts/generate-and-push-pki.sh). Fetched
# Fresh Here Anyway For The Same Reboot-Freshness Reasoning, Even Though
# Staleness Risk Is Lower For Shared Material.
mkdir -p /etc/nomad.d/tls
fetch_secret "nomad-ca-cert" > /etc/nomad.d/tls/ca.pem
fetch_secret "nomad-server-cert" > /etc/nomad.d/tls/cert.pem
fetch_secret "nomad-server-tls-key" > /etc/nomad.d/tls/key.pem
fetch_secret "vault-cert" > /etc/nomad.d/tls/vault-ca.pem
chown nomad:nomad /etc/nomad.d/tls/ca.pem /etc/nomad.d/tls/cert.pem /etc/nomad.d/tls/key.pem /etc/nomad.d/tls/vault-ca.pem
chmod 0644 /etc/nomad.d/tls/ca.pem /etc/nomad.d/tls/cert.pem /etc/nomad.d/tls/vault-ca.pem
chmod 0600 /etc/nomad.d/tls/key.pem

# nomad-gossip-key — Shared, Not Per-Environment (Same Reasoning As The
# Nomad Leaf Cert). Server-Only — Nomad Clients Don't Participate In
# This Gossip Pool At All.
NOMAD_GOSSIP_KEY="$(fetch_secret "nomad-gossip-key")"

# Convert Comma-Separated retry_join Into A JSON Array.
IFS=',' read -ra RETRY_JOIN_ARR <<< "${RETRY_JOIN_CSV}"
RETRY_JOIN_HCL="["
for addr in "${RETRY_JOIN_ARR[@]}"; do
  RETRY_JOIN_HCL+="\"${addr}\", "
done
RETRY_JOIN_HCL="${RETRY_JOIN_HCL%, }]"

echo "[nomad-server-startup] env=${ENVIRONMENT} dc=${DATACENTER} bootstrap_expect=${BOOTSTRAP_EXPECT} ip=${PRIVATE_IP}"

# --- Consul Instance Config ---
cat > /etc/consul.d/99-instance.hcl <<EOF
datacenter = "${DATACENTER}"
node_name  = "${NODE_NAME}"

bind_addr      = "0.0.0.0"
advertise_addr = "${PRIVATE_IP}"

retry_join = ${RETRY_JOIN_HCL}

bootstrap_expect = ${BOOTSTRAP_EXPECT}

encrypt = "${CONSUL_GOSSIP_KEY}"
EOF
chown consul:consul /etc/consul.d/99-instance.hcl
chmod 0640 /etc/consul.d/99-instance.hcl

# --- Nomad Instance Config ---
cat > /etc/nomad.d/99-instance.hcl <<EOF
datacenter = "${DATACENTER}"
name       = "${NODE_NAME}"

bind_addr = "0.0.0.0"

advertise {
  http = "${PRIVATE_IP}"
  rpc  = "${PRIVATE_IP}"
  serf = "${PRIVATE_IP}"
}

server {
  bootstrap_expect = ${BOOTSTRAP_EXPECT}
  server_join {
    retry_join = ${RETRY_JOIN_HCL}
  }
  encrypt = "${NOMAD_GOSSIP_KEY}"
}

vault {
  jwt_auth_backend_path = "jwt-nomad-${ENVIRONMENT}"
}
EOF
chown nomad:nomad /etc/nomad.d/99-instance.hcl
chmod 0640 /etc/nomad.d/99-instance.hcl

# --- Start Consul, Wait, Apply Agent Token, Then Start Nomad ---
systemctl restart consul

for i in $(seq 1 30); do
  if consul members >/dev/null 2>&1; then
    echo "[nomad-server-startup] Consul is responsive."
    break
  fi
  sleep 2
done

if [ -n "${CONSUL_SERVER_TOKEN}" ]; then
  consul acl set-agent-token agent "${CONSUL_SERVER_TOKEN}" || \
    echo "[nomad-server-startup] Failed to set agent token — platform-config may not have created it yet."
fi

systemctl restart nomad

for i in $(seq 1 30); do
  if nomad node status -self >/dev/null 2>&1; then
    echo "[nomad-server-startup] Nomad is responsive."
    break
  fi
  sleep 2
done

echo "[nomad-server-startup] Done."
