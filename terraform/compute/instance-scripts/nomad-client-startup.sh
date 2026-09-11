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
#
# ACL Token Bootstrap Ordering — Gated, Not Assumed:
# consul-client-agent-token-${ENVIRONMENT} And
# nomad-client-consul-token-${ENVIRONMENT} Don't Exist Until AFTER The
# Nomad Servers Have Been ACL-Bootstrapped And platform-config Terraform
# Has Minted The Real Tokens. fetch_token_optional Below Falls Back To An
# Empty String If Either Secret Isn't There Yet, Same As The Server
# Script. Nomad Clients On A MIG Reboot/Reimage Routinely, So The Next
# Boot After Terraform Creates The Tokens Picks Them Up Automatically —
# No Manual Intervention Needed On This Node Type.

set -euo pipefail

METADATA_URL="http://metadata.google.internal/computeMetadata/v1/instance"
METADATA_HEADER="Metadata-Flavor: Google"

get_metadata() {
  curl -sf -H "${METADATA_HEADER}" "${METADATA_URL}/attributes/$1"
}

# --- Values Supplied By Terraform Via Instance Metadata ---
ENVIRONMENT="$(get_metadata env)"
DATACENTER="$(get_metadata datacenter)"
NODE_CLASS="$(get_metadata node_class)"
NODE_POOL="$(get_metadata node_pool)"

# --- Values Supplied By the Compute Engine Metadata Server ---
ZONE="$(curl -sf -H "${METADATA_HEADER}" \
  "${METADATA_URL}/zone" | awk -F/ '{print $NF}')"

REGION="${ZONE%-[a-z]}"

PRIVATE_IP="$(curl -sf -H "${METADATA_HEADER}" \
  "${METADATA_URL}/network-interfaces/0/ip")"

NODE_NAME="$(hostname)"

printf 'environment=%s\n' "$ENVIRONMENT"
printf 'datacenter=%s\n' "$DATACENTER"
printf 'node_pool=%s\n' "$NODE_POOL"
printf 'node_class=%s\n' "$NODE_CLASS"
printf 'zone=%s\n' "$ZONE"
printf 'region=%s\n' "$REGION"
printf 'private_ip=%s\n' "$PRIVATE_IP"
printf 'node_name=%s\n' "$NODE_NAME"

GCP_PROJECT="$(curl -sf -H "${METADATA_HEADER}" \
  "http://metadata.google.internal/computeMetadata/v1/project/project-id")"

# Configure Docker to use gcloud as a credential helper for Artifact Registry
gcloud auth configure-docker ${REGION}-docker.pkg.dev --quiet

# Required Secret — Hard-Fails The Script (Via set -e) If Missing. Use
# For Certs/Gossip Keys, Which Must Always Exist By The Time A Client
# Boots (Pushed By generate-and-push-pki.sh Before Any Instance Is
# Created).
fetch_secret() {
  local secret_name="$1"
  gcloud secrets versions access latest --secret="${secret_name}" --project="${GCP_PROJECT}"
}

# Optional Secret — Never Fails The Script. Used For ACL Tokens That
# Genuinely Don't Exist Until After The Servers' ACL Bootstrap +
# Terraform Have Run. Logs To Stderr So The Outcome Is Visible In Cloud
# Logging Without Polluting The Captured Value On Stdout.
fetch_token_optional() {
  local secret_name="$1"
  local label="$2"
  local value
  if value="$(gcloud secrets versions access latest --secret="${secret_name}" --project="${GCP_PROJECT}" 2>/dev/null)"; then
    echo "[nomad-client-startup] ${label}: found, applying." >&2
    printf '%s' "${value}"
  else
    echo "[nomad-client-startup] ${label}: not created yet (expected before ACL bootstrap), using empty token." >&2
    printf ''
  fi
}

# --- Cloud Auto-Join Discover Strings — Same Target Regardless Of
# Whether The LOCAL Agent Is Server Or Client Mode, Since Both Always
# Discover SERVERS, Never Other Clients. ---
CONSUL_DISCOVER="provider=gce project_name=${GCP_PROJECT} tag_value=consul-server-${ENVIRONMENT}"
NOMAD_DISCOVER="provider=gce project_name=${GCP_PROJECT} tag_value=nomad-server-${ENVIRONMENT}"

# --- Fetch Everything From Secret Manager ---
# CA Is Per-Environment And Shared Between Consul And Nomad — Both Are
# Signed Off The Same ${ENVIRONMENT} CA By generate-and-push-pki.sh, So
# It's Fetched Once And Written To Both Trust Stores Below.
mkdir -p /etc/consul.d/tls /etc/nomad.d/tls
fetch_secret "ca-cert-${ENVIRONMENT}" > /etc/consul.d/tls/ca.pem
fetch_secret "ca-cert-${ENVIRONMENT}" > /etc/nomad.d/tls/ca.pem

# Consul Client Leaf Cert/Key — Per-Environment.
fetch_secret "consul-client-cert-${ENVIRONMENT}" > /etc/consul.d/tls/cert.pem
fetch_secret "consul-client-tls-key-${ENVIRONMENT}" > /etc/consul.d/tls/key.pem
chown consul:consul /etc/consul.d/tls/ca.pem /etc/consul.d/tls/cert.pem /etc/consul.d/tls/key.pem
chmod 0644 /etc/consul.d/tls/ca.pem /etc/consul.d/tls/cert.pem
chmod 0600 /etc/consul.d/tls/key.pem

CONSUL_GOSSIP_KEY="$(fetch_secret "consul-gossip-key-${ENVIRONMENT}")"

# consul-client-agent-token-{env} — Consul's OWN Agent Token
# (acl.tokens.agent), Narrow Node-Identity Scope. Distinct From Nomad's
# Own Consul Token Below.
CONSUL_AGENT_TOKEN="$(fetch_token_optional "consul-client-agent-token-${ENVIRONMENT}" "Consul client agent token")"
CONSUL_DNS_TOKEN="$(fetch_token_optional "consul-dns-token-${ENVIRONMENT}" "Consul DNS default token")"

# nomad-client-consul-token-{env} — NOMAD'S OWN Token For Its consul{}
# Block (Client Variant — Narrower Than The Server Variant, No acl/mesh
# write).
NOMAD_CONSUL_TOKEN="$(fetch_token_optional "nomad-client-consul-token-${ENVIRONMENT}" "Nomad client's Consul token")"

# Nomad Client Leaf Cert/Key — Per-Environment, Signed By The Same CA As
# Consul (See Above).
fetch_secret "nomad-client-cert-${ENVIRONMENT}" > /etc/nomad.d/tls/cert.pem
fetch_secret "nomad-client-tls-key-${ENVIRONMENT}" > /etc/nomad.d/tls/key.pem

# vault-ca.pem — Trust Anchor For Verifying Vault's Server TLS Cert. Must
# Be The CA That Signed Vault's Leaf (management-ca-cert), Not Vault's
# Own Leaf Cert (vault-cert) — The Leaf Isn't A CA, So Using It Here
# Wouldn't Do Real Chain Verification.
fetch_secret "management-ca-cert" > /etc/nomad.d/tls/vault-ca.pem

chown nomad:nomad /etc/nomad.d/tls/ca.pem /etc/nomad.d/tls/cert.pem /etc/nomad.d/tls/key.pem /etc/nomad.d/tls/vault-ca.pem
chmod 0644 /etc/nomad.d/tls/ca.pem /etc/nomad.d/tls/cert.pem /etc/nomad.d/tls/vault-ca.pem
chmod 0600 /etc/nomad.d/tls/key.pem

echo "[nomad-client-startup] env=${ENVIRONMENT} dc=${DATACENTER} pool=${NODE_POOL} class=${NODE_CLASS} ip=${PRIVATE_IP}"

# --- Consul Instance Config ---
# Agent Token In The Config File (acl.tokens.agent), Not A Separate
# `consul acl set-agent-token` CLI Call — Per Consul's Own Bootstrap
# Docs's Explicit Recommendation.
cat > /etc/consul.d/99-instance.hcl <<EOF
datacenter = "${DATACENTER}"
node_name  = "${NODE_NAME}"

bind_addr      = "0.0.0.0"
client_addr    = "0.0.0.0"
advertise_addr = "${PRIVATE_IP}"

retry_join = ["${CONSUL_DISCOVER}"]

encrypt = "${CONSUL_GOSSIP_KEY}"

acl {
  tokens {
    agent = "${CONSUL_AGENT_TOKEN}"
    dns     = "${CONSUL_DNS_TOKEN}"
  }
}
EOF
chown consul:consul /etc/consul.d/99-instance.hcl
chmod 0640 /etc/consul.d/99-instance.hcl

# --- Nomad Instance Config ---
cat > /etc/nomad.d/99-instance.hcl <<EOF
datacenter = "${DATACENTER}"
region     = "${ENVIRONMENT}"
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
  node_class = "${NODE_CLASS}"
  node_pool = "${NODE_POOL}"

  meta {
    node_pool = "${NODE_POOL}"
    env            = "${ENVIRONMENT}"
    node_class     = "${NODE_CLASS}"
  }
}

consul {
  token = "${NOMAD_CONSUL_TOKEN}"
}

vault {
  enabled = true
  address                = "https://vault.platform.lefrancis.org:8443"
  jwt_auth_backend_path  = "jwt-nomad-${ENVIRONMENT}"
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

# Use Dnsmasq As The Single DNS Resolver For Both The Host And Any
# Docker-Bridge-Networked Containers, Forwarding *.Consul Queries To
# Consul's DNS Interface (127.0.0.1:8600) And Everything Else Upstream
# To The GCE Metadata Server. 
systemctl disable --now systemd-resolved

apt-get update -qq
apt-get install -y dnsmasq

DOCKER_BRIDGE_IP="$(docker network inspect bridge --format '{{(index .IPAM.Config 0).Gateway}}')"
cat > /etc/dnsmasq.d/consul.conf <<EOF
listen-address=127.0.0.1,${DOCKER_BRIDGE_IP}
bind-interfaces
no-resolv
server=/consul/127.0.0.1#8600
server=169.254.169.254
EOF
systemctl restart dnsmasq

# Write /Etc/Resolv.Conf As A Real Static File Pointing At Dnsmasq,
# Then Mark It Immutable So Nothing (GCE Guest Agent, DHCP Hooks,
# Systemd-Resolved) Can Silently Rewrite It On A Later Boot Or Network
# Event. chattr -i First So Re-Running This On A Later Boot Doesn't
# Fail On An Already-Immutable File From A Prior Boot.
chattr -i /etc/resolv.conf 2>/dev/null || true
rm -f /etc/resolv.conf
cat > /etc/resolv.conf <<EOF
nameserver 127.0.0.1
search ${ZONE%-*}.c.${GCP_PROJECT}.internal c.${GCP_PROJECT}.internal google.internal
EOF
chattr +i /etc/resolv.conf

echo "[nomad-client-startup] Done."