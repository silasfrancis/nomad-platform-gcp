#!/bin/bash
# scripts/update-hosts.sh
#
# Every provider address in dev/, prod/, and mgmt/ uses a real hostname
# because traefik-internal routes by Host header/SNI —
# the IAP tunnel from open-tunnel.sh only forwards a *port*, so these
# names need to resolve to 127.0.0.1 locally before any of that works.

set -euo pipefail
MARKER="# nomad-platform-gcp — traefik-internal"

# Generic check for WSL across any distribution
is_wsl() {
    [ -n "${WSL_INTEROP:-}" ] || \
    grep -qi microsoft /proc/version 2>/dev/null || \
    grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null
}

# Warn WSL users about auto-generation
if is_wsl; then
    WSL_CONFIGURED=false
    if grep -qE "generateHosts\s*=\s*false" /etc/wsl.conf 2>/dev/null; then
        WSL_CONFIGURED=true
    fi

    if [ "$WSL_CONFIGURED" = false ]; then
        echo "------------------------------------------------------------------"
        echo "WSL environment detected! Run this once to configure /etc/wsl.conf"
        echo "(this stops WSL from automatically erasing your hosts file):"
        echo "------------------------------------------------------------------"
        cat << 'WSL_EOF'
sudo tee -a /etc/wsl.conf <<'EOF'
[network]
generateHosts = false
EOF
WSL_EOF
        echo
    fi

    echo "------------------------------------------------------------------"
    echo "WSL note: this only updates WSL's own /etc/hosts. If you browse"
    echo "from a native Windows browser (not one running inside WSL/WSLg),"
    echo "Windows resolves hostnames via its OWN separate hosts file —"
    echo "WSL and Windows do not share /etc/hosts."
    echo
    echo "Add the same block below to:"
    echo "  C:\\Windows\\System32\\drivers\\etc\\hosts"
    echo "(edit via Notepad running as Administrator — the file has no"
    echo "extension, so set Notepad's file filter to \"All Files\" to see it)"
    echo "------------------------------------------------------------------"
    echo
fi

# Print block for /etc/hosts
if grep -q "${MARKER}" /etc/hosts 2>/dev/null; then
    echo "------------------------------------------------------------------"
    echo "Status: Marker '${MARKER}' already found in /etc/hosts."
    echo "No update needed."
    echo "------------------------------------------------------------------"
else
    echo "------------------------------------------------------------------"
    echo "Run this block to update /etc/hosts:"
    echo "------------------------------------------------------------------"
    cat << HOSTS_EOF
sudo tee -a /etc/hosts <<'EOF'
${MARKER}
127.0.0.1 vault.platform.lefrancis.org
127.0.0.1 octopus.platform.lefrancis.org
127.0.0.1 grafana.platform.lefrancis.org
127.0.0.1 nomad-dev.platform.lefrancis.org
127.0.0.1 consul-dev.platform.lefrancis.org
127.0.0.1 nomad-prod.platform.lefrancis.org
127.0.0.1 consul-prod.platform.lefrancis.org
EOF
HOSTS_EOF
    echo "------------------------------------------------------------------"
fi