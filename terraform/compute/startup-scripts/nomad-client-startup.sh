#!/bin/bash
# GCE Startup Script — nomad-client-mig Instance Template Only.
#
# Baked Ahead Of Time By Packer (common, consul, nomad, docker, falco Roles):
# binaries, systemd units (enabled, NOT started), baked consul.hcl/nomad.hcl
# (env-independent parts only), Consul/Nomad CA certs, and the shared
# Nomad server/client cert (not per-environment, see roles/nomad). This
# Script Supplies Everything That's Genuinely Per-Instance Or
# Per-Environment: non-secret values Terraform passes via instance
# metadata (datacenter, retry_join, node meta), AND the per-environment
# Consul client TLS cert/key + gossip key, which — unlike the Nomad cert —
# can't be baked into the shared image and are fetched from Secret
# Manager at boot using the instance's own service account token.
#
# Runs On Every Boot (google-startup-scripts.service) — Idempotent By
# Design: It Always Rewrites 99-instance.hcl And Restarts Both Services,
# Which Is Harmless Whether This Is A True First Boot Or A Restart Of An
# Existing Instance.

set -euo pipefail

METADATA_URL="http://metadata.google.internal/computeMetadata/v1/instance"
METADATA_HEADER="Metadata-Flavor: Google"

get_metadata() {
  curl -sf -H "${METADATA_HEADER}" "${METADATA_URL}/attributes/$1"
}

# --- Values Supplied By Terraform Via Instance Metadata ---
# Set On The nomad-client-mig Instance Template — See modules/nomad-client-mig.
ENVIRONMENT="$(get_metadata env)"                     # "dev" or "prod"
DATACENTER="$(get_metadata datacenter)"               # "dc-dev" or "dc-prod"
NODE_POOL_TYPE="$(get_metadata node_pool_type)"       # "on-demand" or "spot"
NODE_CLASS="$(get_metadata node_class)"               # "critical" or "preemptible"
RETRY_JOIN_CSV="$(get_metadata retry_join)"           # comma-separated Consul/Nomad server names

# Own Private IP — See Standing Instruction: bind_addr Must Be The Private
# Interface IP (Or 0.0.0.0), NOT 127.0.0.1, Or GCP's MIG TCP:4646 Health
# Check Will Falsely Mark This Instance Unhealthy.
PRIVATE_IP="$(curl -sf -H "${METADATA_HEADER}" \
  "${METADATA_URL}/network-interfaces/0/ip")"

NODE_NAME="$(hostname)"

# --- Fetch Consul TLS Client Cert/Key + Gossip Key From Secret Manager ---
# These Are Per-Environment And Can't Be Baked Into The Shared Image (See
# roles/consul's Task Comments). Fetched Via The Instance's Own Service
# Account OAuth Token From The Metadata Server — No gcloud CLI Dependency,
# Keeps The Baked Image Minimal. Requires nomad-client-sa To Have
# secretAccessor On Just These 3 Secrets Per Environment (Not The Whole
# app Tier) — See terraform/bootstrap's secret-manager Module.
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

mkdir -p /etc/consul.d/tls
fetch_secret "consul-client-cert-${ENVIRONMENT}" > /etc/consul.d/tls/cert.pem
fetch_secret "consul-client-key-${ENVIRONMENT}" > /etc/consul.d/tls/key.pem
chown consul:consul /etc/consul.d/tls/cert.pem /etc/consul.d/tls/key.pem
chmod 0644 /etc/consul.d/tls/cert.pem
chmod 0600 /etc/consul.d/tls/key.pem

CONSUL_GOSSIP_KEY="$(fetch_secret "consul-gossip-key-${ENVIRONMENT}")"

# Convert Comma-Separated retry_join Into A JSON Array For HCL/Consul-Style
# List Syntax.
IFS=',' read -ra RETRY_JOIN_ARR <<< "${RETRY_JOIN_CSV}"
RETRY_JOIN_HCL="["
for addr in "${RETRY_JOIN_ARR[@]}"; do
  RETRY_JOIN_HCL+="\"${addr}\", "
done
RETRY_JOIN_HCL="${RETRY_JOIN_HCL%, }]"

echo "[nomad-client-startup] env=${ENVIRONMENT} dc=${DATACENTER} pool=${NODE_POOL_TYPE} class=${NODE_CLASS} ip=${PRIVATE_IP}"

# --- Consul Instance Config ---
# encrypt Is Written Here, Not Baked, Since The Baked consul.hcl Omits It
# Entirely When consul_datacenter Was Undefined At Packer Bake Time (See
# roles/consul/templates/consul.hcl.j2).
cat > /etc/consul.d/99-instance.hcl <<EOF
datacenter = "${DATACENTER}"
node_name  = "${NODE_NAME}"

bind_addr      = "0.0.0.0"
advertise_addr = "${PRIVATE_IP}"

retry_join = ${RETRY_JOIN_HCL}

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

client {
  servers = ${RETRY_JOIN_HCL}

  meta {
    node_pool_type = "${NODE_POOL_TYPE}"
    env            = "${ENVIRONMENT}"
    node_class     = "${NODE_CLASS}"
  }
}

vault {
  jwt_auth_backend_path = "jwt-nomad-${ENVIRONMENT}"
}
EOF
chown nomad:nomad /etc/nomad.d/99-instance.hcl
chmod 0640 /etc/nomad.d/99-instance.hcl

# --- Start Consul, Wait, Then Start Nomad ---
systemctl restart consul

for i in $(seq 1 30); do
  if consul members >/dev/null 2>&1; then
    echo "[nomad-client-startup] Consul is responsive."
    break
  fi
  sleep 2
done

systemctl restart nomad

for i in $(seq 1 30); do
  if nomad node status -self >/dev/null 2>&1; then
    echo "[nomad-client-startup] Nomad is responsive."
    break
  fi
  sleep 2
done

echo "[nomad-client-startup] Done."