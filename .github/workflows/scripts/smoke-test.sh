#!/bin/bash
# smoke-test.sh
#
# Confirms the newly-deployed service actually responds before treating
# the release as complete — a job reporting "healthy" to Nomad only
# means the allocation is running, not that the application inside it
# is actually serving traffic correctly.
set -euo pipefail

: "${SERVICE_NAME:?service name to check is required}"

url="http://${SERVICE_NAME}.service.consul/health"
echo "Smoke testing ${url}..."

status_code="$(curl -s -o /dev/null -w '%{http_code}' "${url}" || echo "000")"

if [ "${status_code}" != "200" ]; then
  echo "Smoke test failed — ${url} returned ${status_code}." >&2
  exit 1
fi

echo "Smoke test passed."
