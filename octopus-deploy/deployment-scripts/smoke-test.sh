#!/bin/bash
# smoke-test.sh
#
# Confirms the newly-deployed service actually responds before treating
# the release as complete — a job reporting "healthy" to Nomad only
# means the allocation is running, not that the application inside it
# is actually serving traffic correctly.
#
# FIXED: the original version only ever did an HTTP curl. Checking
# against the actual job specs, only frontend, metrics-api,
# nomad-sentinel, and falco-webhook are HTTP — the other 8 boutique
# services (cartservice, productcatalogservice, currencyservice,
# paymentservice, shippingservice, checkoutservice, adservice,
# recommendationservice) all use type = "grpc" health checks in their
# Consul service registration. A plain curl against a gRPC port
# doesn't get a meaningful response at all — this would have failed
# every smoke test for 8 of the 11 boutique services. Now branches on
# PROTOCOL, matching each service's own health check type.
#
# grpc_health_probe implements gRPC's standard health-checking
# protocol (grpc.health.v1.Health) — needs to be present on the
# runner; not bundled here.
set -euo pipefail

: "${SERVICE_NAME:?service name to check is required}"
PROTOCOL="${PROTOCOL:-http}"

if [ "${PROTOCOL}" = "grpc" ]; then
  : "${SERVICE_PORT:?SERVICE_PORT is required when PROTOCOL=grpc}"
  target="${SERVICE_NAME}.service.consul:${SERVICE_PORT}"
  echo "Smoke testing gRPC health on ${target}..."

  if ! command -v grpc_health_probe &> /dev/null; then
    echo "ERROR: grpc_health_probe not found on this runner." >&2
    exit 1
  fi

  if ! grpc_health_probe -addr="${target}"; then
    echo "Smoke test failed — gRPC health check against ${target} did not report SERVING." >&2
    exit 1
  fi
else
  url="http://${SERVICE_NAME}.service.consul/health"
  echo "Smoke testing ${url}..."

  status_code="$(curl -s -o /dev/null -w '%{http_code}' "${url}" || echo "000")"

  if [ "${status_code}" != "200" ]; then
    echo "Smoke test failed — ${url} returned ${status_code}." >&2
    exit 1
  fi
fi

echo "Smoke test passed."
