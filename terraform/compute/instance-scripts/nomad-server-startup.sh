#!/bin/bash
# GCE Startup Script — nomad-server Static Instances Only (Both dev And
# prod, Terraform Passes The Right Metadata Per-Instance).
#
# Ansible's Job (mgmt.yaml/nomad-servers.yaml): Install Binaries, Create
# Users/Directories, Template The Systemd Units, Enable (NOT Start) The
# Services. Per The Latest PKI Redesign, NOTHING Secret-Related Is Baked
# Or Written By Ansible Either — Every CA Cert, Leaf Cert/Key, Gossip
# Key, And Token Is Fetched Here, At Boot, Same As The Client Script, For
# One Consistent Mental Model Across Both Node Types.
#
# gcloud CLI Is Used Directly For Every Secret Manager Read — Present Via
# The common Role's common_install_gcloud_cli Toggle.
#
# retry_join Is Supplied Via GCE Cloud Auto-Join (provider=gce, Tag-Based
# Discovery), Not A Literal Address List — See nomad-client-startup.sh's
# Header For The Same Reasoning And Requirements (Environment-Specific
# Tags, compute.instances.list Permission).
#
# Runs On Every Boot — Idempotent By Design. Secrets/Certs/Tokens Get
# Re-Fetched Fresh On Every Reboot (Patching, Maintenance, Host
# Migration), So A Rotated Token Or Cert Is Picked Up Automatically On
# The Next Restart, No Manual Ansible Re-Run Needed.

set -euo pipefail

METADATA_URL="http://metadata.google.internal/computeMetadata/v1/instance"
METADATA_HEADER="Metadata-Flavor: Google"

get_metadata() {
  curl -sf -H "${METADATA_HEADER}" "${METADATA_URL}/attributes/$1"
}

# --- Values Supplied By Terraform Via Instance Metadata ---
ENVIRONMENT="$(get_metadata env)"                    # "dev" or "prod"
DATACENTER="$(get_metadata datacenter)"              # "dc-dev" or "dc-prod"
BOOTSTRAP_EXPECT="$(get_metadata bootstrap_expect)"  # "1" (dev) or "3" (prod)

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
# Whether The LOCAL Agent Is Server Or Client Mode. ---
CONSUL_DISCOVER="provider=gce project_name=${GCP_PROJECT} tag_value=consul-server-${ENVIRONMENT}"
NOMAD_DISCOVER="provider=gce project_name=${GCP_PROJECT} tag_value=nomad-server-${ENVIRONMENT}"

# --- Fetch Everything From Secret Manager ---
# Consul: CA + Server Leaf Cert/Key Are Per-Environment (Consul's
# Hostname Verification Requires It). Consul's Own Agent Token Is Narrow
# (Node-Identity Scope Only).
mkdir -p /etc/consul.d/tls
fetch_secret "consul-ca-cert" > /etc/consul.d/tls/ca.pem
fetch_secret "consul-server-cert-${ENVIRONMENT}" > /etc/consul.d/tls/cert.pem
fetch_secret "consul-server-key-${ENVIRONMENT}" > /etc/consul.d/tls/key.pem
chown consul:consul /etc/consul.d/tls/ca.pem /etc/consul.d/tls/cert.pem /etc/consul.d/tls/key.pem
chmod 0644 /etc/consul.d/tls/ca.pem /etc/consul.d/tls/cert.pem
chmod 0600 /etc/consul.d/tls/key.pem

CONSUL_GOSSIP_KEY="$(fetch_secret "consul-gossip-key-${ENVIRONMENT}")"
CONSUL_AGENT_TOKEN="$(fetch_secret "consul-server-agent-token-${ENVIRONMENT}" || echo "")"

# nomad-server-consul-token-{env} — NOMAD'S OWN Token For Its consul{}
# Block (Server Variant — Broader Than The Client Variant, Includes
# acl/mesh write For Consul Connect Config Entries).
NOMAD_CONSUL_TOKEN="$(fetch_secret "nomad-server-consul-token-${ENVIRONMENT}" || echo "")"

# Nomad: CA + Server Leaf Cert/Key Are Shared, Not Per-Environment (Dev/
# Prod Never Federate).
mkdir -p /etc/nomad.d/tls
fetch_secret "nomad-ca-cert" > /etc/nomad.d/tls/ca.pem
fetch_secret "nomad-server-cert" > /etc/nomad.d/tls/cert.pem
fetch_secret "nomad-server-tls-key" > /etc/nomad.d/tls/key.pem
fetch_secret "vault-cert" > /etc/nomad.d/tls/vault-ca.pem
chown nomad:nomad /etc/nomad.d/tls/ca.pem /etc/nomad.d/tls/cert.pem /etc/nomad.d/tls/key.pem /etc/nomad.d/tls/vault-ca.pem
chmod 0644 /etc/nomad.d/tls/ca.pem /etc/nomad.d/tls/cert.pem /etc/nomad.d/tls/vault-ca.pem
chmod 0600 /etc/nomad.d/tls/key.pem

# nomad-gossip-key — Shared, Not Per-Environment. Server-Only — Nomad
# Clients Don't Participate In This Gossip Pool At All.
NOMAD_GOSSIP_KEY="$(fetch_secret "nomad-gossip-key-${ENVIRONMENT}")"

echo "[nomad-server-startup] env=${ENVIRONMENT} dc=${DATACENTER} bootstrap_expect=${BOOTSTRAP_EXPECT} ip=${PRIVATE_IP}"

# --- Consul Instance Config ---
cat > /etc/consul.d/99-instance.hcl <<EOF
datacenter = "${DATACENTER}"
node_name  = "${NODE_NAME}"

bind_addr      = "0.0.0.0"
advertise_addr = "${PRIVATE_IP}"

retry_join = ["${CONSUL_DISCOVER}"]

bootstrap_expect = ${BOOTSTRAP_EXPECT}

encrypt = "${CONSUL_GOSSIP_KEY}"

acl {
  tokens {
    agent = "${CONSUL_AGENT_TOKEN}"
  }
}
EOF
chown consul:consul /etc/consul.d/99-instance.hcl
chmod 0640 /etc/consul.d/99-instance.hcl

# Register nomad api as a consul service
cat > /etc/consul.d/nomad.hcl <<EOF
service {
  name    = "nomad"
  id      = "nomad-${NODE_NAME}"
  address = "${PRIVATE_IP}"
  port    = 4646

  check {
    name     = "nomad-metrics"
    http     = "http://127.0.0.1:4646/v1/metrics?format=prometheus"
    interval = "10s"
    timeout  = "5s"
  }
}
EOF

chown consul:consul /etc/consul.d/nomad.hcl
chmod 0640 /etc/consul.d/nomad.hcl

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
    retry_join = ["${NOMAD_DISCOVER}"]
  }
  encrypt = "${NOMAD_GOSSIP_KEY}"
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
    echo "[nomad-server-startup] Consul is responsive."
    break
  fi
  sleep 2
done

systemctl restart nomad

for i in $(seq 1 30); do
  if nomad node status -self >/dev/null 2>&1; then
    echo "[nomad-server-startup] Nomad is responsive."
    break
  fi
  sleep 2
done

echo "[nomad-server-startup] Done."
