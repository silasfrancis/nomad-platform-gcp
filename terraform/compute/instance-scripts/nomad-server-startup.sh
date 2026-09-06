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
# Runs On Every Boot — Idempotent By Design. Certs/Gossip Keys Get
# Re-Fetched Fresh On Every Reboot (Patching, Maintenance, Host
# Migration), So A Rotated Cert Is Picked Up Automatically On The Next
# Restart, No Manual Ansible Re-Run Needed.
#
# ACL Token Bootstrap Ordering — Gated, Not Assumed:
# consul-server-agent-token-${ENVIRONMENT} And
# nomad-server-consul-token-${ENVIRONMENT} Don't Exist Until AFTER
# `consul acl bootstrap` / `nomad acl bootstrap` Have Been Run Against a
# Live Cluster And platform-config Terraform Has Used Those Bootstrap
# Tokens To Mint The Real Ones. On A Server's Very First Boot, Neither
# Secret Exists Yet — fetch_token_optional Below Logs That And Falls
# Back To An Empty String Rather Than Failing The Whole Script. Once
# Terraform Creates The Real Tokens, Reboot The Instance And This Script
# Picks Them Up Automatically. Safe To Reboot Any Time — Raft Data Lives
# On The Separate Persistent Disks Handled By setup_data_disk Below, Not
# The Boot Disk, And That Function Only Formats/Mounts When Needed.

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

# Required Secret — Hard-Fails The Script (Via set -e) If Missing. Use
# For Certs/Gossip Keys, Which Must Always Exist By The Time A Server
# Boots (Pushed By generate-and-push-pki.sh Before Any Instance Is
# Created).
fetch_secret() {
  local secret_name="$1"
  gcloud secrets versions access latest --secret="${secret_name}" --project="${GCP_PROJECT}"
}

# Optional Secret — Never Fails The Script. Used For ACL Tokens That
# Genuinely Don't Exist Until After ACL Bootstrap + Terraform Have Run.
# Logs To Stderr So The Outcome Is Visible In Cloud Logging Without
# Polluting The Captured Value On Stdout.
fetch_token_optional() {
  local secret_name="$1"
  local label="$2"
  local value
  if value="$(gcloud secrets versions access latest --secret="${secret_name}" --project="${GCP_PROJECT}" 2>/dev/null)"; then
    echo "[nomad-server-startup] ${label}: found, applying." >&2
    printf '%s' "${value}"
  else
    echo "[nomad-server-startup] ${label}: not created yet (expected before ACL bootstrap), using empty token." >&2
    printf ''
  fi
}

# --- Cloud Auto-Join Discover Strings — Same Target Regardless Of
# Whether The LOCAL Agent Is Server Or Client Mode. ---
CONSUL_DISCOVER="provider=gce project_name=${GCP_PROJECT} tag_value=consul-server-${ENVIRONMENT}"
NOMAD_DISCOVER="provider=gce project_name=${GCP_PROJECT} tag_value=nomad-server-${ENVIRONMENT}"

# --- Fetch Everything From Secret Manager ---
# CA Is Per-Environment And Shared Between Consul And Nomad — Both Are
# Signed Off The Same ${ENVIRONMENT} CA By generate-and-push-pki.sh, So
# It's Fetched Once And Written To Both Trust Stores Below.
mkdir -p /etc/consul.d/tls /etc/nomad.d/tls
fetch_secret "ca-cert-${ENVIRONMENT}" > /etc/consul.d/tls/ca.pem
fetch_secret "ca-cert-${ENVIRONMENT}" > /etc/nomad.d/tls/ca.pem

# Consul Server Leaf Cert/Key — Per-Environment (Consul's Hostname
# Verification Requires It).
fetch_secret "consul-server-cert-${ENVIRONMENT}" > /etc/consul.d/tls/cert.pem
fetch_secret "consul-server-tls-key-${ENVIRONMENT}" > /etc/consul.d/tls/key.pem
chown consul:consul /etc/consul.d/tls/ca.pem /etc/consul.d/tls/cert.pem /etc/consul.d/tls/key.pem
chmod 0644 /etc/consul.d/tls/ca.pem /etc/consul.d/tls/cert.pem
chmod 0600 /etc/consul.d/tls/key.pem

CONSUL_GOSSIP_KEY="$(fetch_secret "consul-gossip-key-${ENVIRONMENT}")"
CONSUL_AGENT_TOKEN="$(fetch_token_optional "consul-server-agent-token-${ENVIRONMENT}" "Consul server agent token")"
CONSUL_DNS_TOKEN="$(fetch_token_optional "consul-dns-token-${ENVIRONMENT}" "Consul DNS default token")"

# nomad-server-consul-token-{env} — NOMAD'S OWN Token For Its consul{}
# Block (Server Variant — Broader Than The Client Variant, Includes
# acl/mesh write For Consul Connect Config Entries).
NOMAD_CONSUL_TOKEN="$(fetch_token_optional "nomad-server-consul-token-${ENVIRONMENT}" "Nomad server's Consul token")"

# Nomad Server Leaf Cert/Key — Per-Environment, Signed By The Same CA As
# Consul (See Above). Dev/Prod Never Federate, So There's No Cross-Env
# Sharing Here Either.
fetch_secret "nomad-server-cert-${ENVIRONMENT}" > /etc/nomad.d/tls/cert.pem
fetch_secret "nomad-server-tls-key-${ENVIRONMENT}" > /etc/nomad.d/tls/key.pem

# vault-ca.pem — Trust Anchor For Verifying Vault's Server TLS Cert. Must
# Be The CA That Signed Vault's Leaf (management-ca-cert), Not Vault's
# Own Leaf Cert (vault-cert) — The Leaf Isn't A CA, So Using It Here
# Wouldn't Do Real Chain Verification.
fetch_secret "management-ca-cert" > /etc/nomad.d/tls/vault-ca.pem

chown nomad:nomad /etc/nomad.d/tls/ca.pem /etc/nomad.d/tls/cert.pem /etc/nomad.d/tls/key.pem /etc/nomad.d/tls/vault-ca.pem
chmod 0644 /etc/nomad.d/tls/ca.pem /etc/nomad.d/tls/cert.pem /etc/nomad.d/tls/vault-ca.pem
chmod 0600 /etc/nomad.d/tls/key.pem

# nomad-gossip-key — Per-Environment. Server-Only — Nomad Clients Don't
# Participate In This Gossip Pool At All.
NOMAD_GOSSIP_KEY="$(fetch_secret "nomad-gossip-key-${ENVIRONMENT}")"

echo "[nomad-server-startup] env=${ENVIRONMENT} dc=${DATACENTER} bootstrap_expect=${BOOTSTRAP_EXPECT} ip=${PRIVATE_IP}"

# Data Disk Setup
# Nomad and Consul Raft data live on dedicated persistent disks, not the
# boot disk. This script only formats if blkid finds no filesystem and only mounts if not already mounted.

wait_for_device() {
  local device="$1"
  for i in $(seq 1 30); do
    if [[ -e "${device}" ]]; then
      echo "[nomad-server-startup] Device ${device} present after $((i*2))s."
      return 0
    fi
    sleep 2
  done
  echo "[nomad-server-startup] ERROR: ${device} did not appear after 90s." >&2
  exit 1
}

setup_data_disk() {
  local disk_name="$1"   # Terraform disk resource name, e.g. "nomad-data"
  local mount_dir="$2"   # e.g. "/opt/nomad/data"
  local owner="$3"
  local group="$4"
  local device="/dev/disk/by-id/google-${disk_name}"

  wait_for_device "${device}"
  mkdir -p "${mount_dir}"

  if ! blkid "${device}" >/dev/null 2>&1; then
    echo "[nomad-server-startup] Formatting ${disk_name} (no filesystem found)."
    mkfs.ext4 -F "${device}"
  fi

  if ! mountpoint -q "${mount_dir}"; then
    mount -t ext4 "${device}" "${mount_dir}"
    echo "[nomad-server-startup] Mounted ${device} at ${mount_dir}."
  fi

  chown "${owner}:${group}" "${mount_dir}"
  chmod 0750 "${mount_dir}"
}

setup_data_disk "consul-data" "/opt/consul/data" "consul" "consul"
setup_data_disk "nomad-data"  "/opt/nomad/data"  "nomad"  "nomad"

# --- Consul Instance Config ---
cat > /etc/consul.d/99-instance.hcl <<EOF
datacenter = "${DATACENTER}"
node_name  = "${NODE_NAME}"

bind_addr      = "0.0.0.0"
client_addr    = "0.0.0.0"
advertise_addr = "${PRIVATE_IP}"

retry_join = ["${CONSUL_DISCOVER}"]

bootstrap_expect = ${BOOTSTRAP_EXPECT}

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

# Register nomad api as a consul service
cat > /etc/consul.d/nomad.hcl <<EOF
service {
  name    = "nomad"
  id      = "nomad-${NODE_NAME}"
  address = "${PRIVATE_IP}"
  port    = 4646
  token   = "${CONSUL_AGENT_TOKEN}"

  check {
    name            = "nomad-metrics"
    http            = "https://127.0.0.1:4646/v1/metrics?format=prometheus"
    tls_skip_verify = true
    interval        = "10s"
    timeout         = "5s"
  }
}
EOF

chown consul:consul /etc/consul.d/nomad.hcl
chmod 0640 /etc/consul.d/nomad.hcl

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
  enabled = true
  
  default_identity {
    aud  = ["vault.io"]
    ttl  = "1h"
    file = true
  }
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

# Configure Systemd-Resolved To Route *.Consul DNS Queries To Consul's
# Own DNS Interface (127.0.0.1:8600) Rather Than The Default Upstream
# (GCE Metadata Server), Which Has No Knowledge Of Consul-Registered
# Names.
mkdir -p /etc/systemd/resolved.conf.d
cat > /etc/systemd/resolved.conf.d/consul.conf <<'EOF'
[Resolve]
DNS=127.0.0.1:8600
Domains=~consul
EOF
systemctl restart systemd-resolved

# Force /Etc/Resolv.Conf To Point At Systemd-Resolved's Stub Listener
# (127.0.0.53) 
ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

echo "[nomad-server-startup] Done." 