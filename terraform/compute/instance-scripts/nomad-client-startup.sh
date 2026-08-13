#!/bin/bash
# GCE Startup Script — nomad-client-mig Instance Template Only.
#
# Baked Ahead Of Time By Packer (common, consul, nomad, docker, falco
# Roles): Binaries, Systemd Units (Enabled, NOT Started) — Nothing Else.
# Per The Latest PKI Redesign, Packer Bakes ZERO Certificates/Keys/Secrets
# Of Any Kind — Every CA Cert, Leaf Cert/Key, Gossip Key, And Token Is
# Fetched Here, At Boot, Using This Instance's Own Service Account.
# Images Are Fully Environment-Agnostic.
#
# gcloud CLI Is Used Directly For Every Secret Manager Read — Already
# Present In The Baked Image Via The common Role's
# common_install_gcloud_cli Toggle (Set True In nomad-clients.yaml, The
# Same Playbook Packer's Provisioner Runs), So There's No Need For The
# Raw curl+REST+OAuth-Token Approach An Earlier Version Of This Script
# Used.
#
# retry_join Is No Longer Supplied Via Instance Metadata — GCE Cloud
# Auto-Join (provider=gce, Tag-Based Discovery) Replaces It Entirely, So
# Terraform Doesn't Need To Compute/Pass An Address List That Would Go
# Stale If Server Count Ever Changes. REQUIRES: nomad-server Instances
# Tagged With Environment-Specific Tags (consul-server-dev/prod,
# nomad-server-dev/prod — NOT A Shared "nomad-server" Tag Across Both
# Envs, Or Auto-Join Would Cross Environments). REQUIRES: This Instance's
# Service Account Has compute.instances.list (Or roles/compute.viewer).
#
# Runs On Every Boot — Idempotent By Design.

set -euo pipefail

METADATA_URL="http://metadata.google.internal/computeMetadata/v1/instance"
METADATA_HEADER="Metadata-Flavor: Google"

get_metadata() {
  curl -sf -H "${METADATA_HEADER}" "${METADATA_URL}/attributes/$1"
}

# --- Values Supplied By Terraform Via Instance Metadata ---
ENVIRONMENT="$(get_metadata env)"                 # "dev" or "prod"
DATACENTER="$(get_metadata datacenter)"           # "dc-dev" or "dc-prod"
NODE_POOL_TYPE="$(get_metadata node_pool_type)"   # "on-demand" or "spot"
NODE_CLASS="$(get_metadata node_class)"           # "critical" or "preemptible"

PRIVATE_IP="$(curl -sf -H "${METADATA_HEADER}" \
  "${METADATA_URL}/network-interfaces/0/ip")"

NODE_NAME="$(hostname)"

GCP_PROJECT="$(curl -sf -H "${METADATA_HEADER}" \
  "http://metadata.google.internal/computeMetadata/v1/project/project-id")"

fetch_secret() {
  local secret_name="$1"
  gcloud secrets versions access latest --secret="${secret_name}" --project="${GCP_PROJECT}"
}

# --- Cloud Auto-Join Discover Strings — Same Target Regardless Of
# Whether The LOCAL Agent Is Server Or Client Mode, Since Both Always
# Discover SERVERS, Never Other Clients. ---
CONSUL_DISCOVER="provider=gce project_name=${GCP_PROJECT} tag_value=consul-server-${ENVIRONMENT}"
NOMAD_DISCOVER="provider=gce project_name=${GCP_PROJECT} tag_value=nomad-server-${ENVIRONMENT}"

# --- Fetch Everything From Secret Manager ---
mkdir -p /etc/consul.d/tls
fetch_secret "consul-ca-cert" > /etc/consul.d/tls/ca.pem
fetch_secret "consul-client-cert-${ENVIRONMENT}" > /etc/consul.d/tls/cert.pem
fetch_secret "consul-client-key-${ENVIRONMENT}" > /etc/consul.d/tls/key.pem
chown consul:consul /etc/consul.d/tls/ca.pem /etc/consul.d/tls/cert.pem /etc/consul.d/tls/key.pem
chmod 0644 /etc/consul.d/tls/ca.pem /etc/consul.d/tls/cert.pem
chmod 0600 /etc/consul.d/tls/key.pem

CONSUL_GOSSIP_KEY="$(fetch_secret "consul-gossip-key-${ENVIRONMENT}")"

# consul-client-agent-token-{env} — Consul's OWN Agent Token
# (acl.tokens.agent), Narrow Node-Identity Scope. Distinct From Nomad's
# Own Consul Token Below. Falls Back To Empty If platform-config Hasn't
# Created It Yet, Rather Than Failing The Whole Boot.
CONSUL_AGENT_TOKEN="$(fetch_secret "consul-client-agent-token-${ENVIRONMENT}" || echo "")"

# nomad-client-consul-token-{env} — NOMAD'S OWN Token For Its consul{}
# Block (Client Variant — Narrower Than The Server Variant, No acl/mesh
# write).
NOMAD_CONSUL_TOKEN="$(fetch_secret "nomad-client-consul-token-${ENVIRONMENT}" || echo "")"

mkdir -p /etc/nomad.d/tls
fetch_secret "nomad-ca-cert" > /etc/nomad.d/tls/ca.pem
fetch_secret "nomad-client-cert" > /etc/nomad.d/tls/cert.pem
fetch_secret "nomad-client-tls-key" > /etc/nomad.d/tls/key.pem
fetch_secret "vault-cert" > /etc/nomad.d/tls/vault-ca.pem
chown nomad:nomad /etc/nomad.d/tls/ca.pem /etc/nomad.d/tls/cert.pem /etc/nomad.d/tls/key.pem /etc/nomad.d/tls/vault-ca.pem
chmod 0644 /etc/nomad.d/tls/ca.pem /etc/nomad.d/tls/cert.pem /etc/nomad.d/tls/vault-ca.pem
chmod 0600 /etc/nomad.d/tls/key.pem

echo "[nomad-client-startup] env=${ENVIRONMENT} dc=${DATACENTER} pool=${NODE_POOL_TYPE} class=${NODE_CLASS} ip=${PRIVATE_IP}"

# --- Consul Instance Config ---
# Agent Token In The Config File (acl.tokens.agent), Not A Separate
# `consul acl set-agent-token` CLI Call — Per Consul's Own Bootstrap
# Docs's Explicit Recommendation.
cat > /etc/consul.d/99-instance.hcl <<EOF
datacenter = "${DATACENTER}"
node_name  = "${NODE_NAME}"

bind_addr      = "0.0.0.0"
advertise_addr = "${PRIVATE_IP}"

retry_join = ["${CONSUL_DISCOVER}"]

encrypt = "${CONSUL_GOSSIP_KEY}"

acl {
  tokens {
    agent = "${CONSUL_AGENT_TOKEN}"
  }
}
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
  server_join {
    retry_join = ["${NOMAD_DISCOVER}"]
  }

  meta {
    node_pool_type = "${NODE_POOL_TYPE}"
    env            = "${ENVIRONMENT}"
    node_class     = "${NODE_CLASS}"
  }
}

consul {
  token = "${NOMAD_CONSUL_TOKEN}"
}

vault {
  jwt_auth_backend_path = "jwt-nomad-${ENVIRONMENT}"
}
EOF
chown nomad:nomad /etc/nomad.d/99-instance.hcl
chmod 0640 /etc/nomad.d/99-instance.hcl

# --- Start Consul, Then Nomad ---
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

# Set Falco Webhook URL config based on environment
if [ "${ENVIRONMENT}" = "prod" ]; then
    TRAEFIK_INTERNAL_ENNTRY_PORT="8447"
else
    TRAEFIK_INTERNAL_ENNTRY_PORT="8446"
fi

FALCO_WEBHOOK_URL="https://falco-webhook-${ENVIRONMENT}.platform.lefrancis.org:${TRAEFIK_INTERNAL_ENNTRY_PORT}"

# Replace the placeholder simply and cleanly
sed -i "s|__FALCO_WEBHOOK_URL__|${FALCO_WEBHOOK_URL}|g" /etc/falco/falco.yaml

systemctl restart falco

echo "[nomad-client-startup] Done."
