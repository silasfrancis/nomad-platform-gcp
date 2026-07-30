#!/bin/bash
# scripts/update-hosts.sh
#
# Every provider address in dev/, prod/, and mgmt/ uses a real hostname
# (not localhost) because traefik-internal routes by Host header/SNI —
# the IAP tunnel from open-tunnel.sh only forwards a *port*, so these
# names need to resolve to 127.0.0.1 locally before any of that works.
#
# This only ever prints the block to add — it does not write to
# /etc/hosts itself, since that needs sudo and this script has no
# business escalating on its own. Run once per machine; safe to run
# again (checks for the marker before printing).

set -euo pipefail
MARKER="# nomad-platform-gcp — traefik-internal"

if grep -q "${MARKER}" /etc/hosts 2>/dev/null; then
  echo "Already present in /etc/hosts (marker found). Nothing to do."
  exit 0
fi

cat << HOSTS

Add this block to /etc/hosts (e.g. sudo tee -a /etc/hosts <<< the block below):

${MARKER}
127.0.0.1 vault.platform.lefrancis.org
127.0.0.1 octopus.platform.lefrancis.org
127.0.0.1 grafana.platform.lefrancis.org
127.0.0.1 nomad-dev.platform.lefrancis.org
127.0.0.1 consul-dev.platform.lefrancis.org
127.0.0.1 nomad-prod.platform.lefrancis.org
127.0.0.1 consul-prod.platform.lefrancis.org

HOSTS
