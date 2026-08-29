#!/bin/bash
# smoke-test.sh
#
# Confirms every newly-deployed service actually responds before
# treating the release as complete — Nomad reporting an allocation
# "healthy" only means the process is running, not that it's serving
# traffic correctly.

# VERIFY: the jq paths below assume `nomad job inspect -json`'s
# .Job.TaskGroups[].Services[].Checks[].Type field matches the HCL
# check block's `type` value directly (e.g. "http"/"grpc") — this
# matches the documented job spec shape but hasn't been checked here
# against real inspect output; confirm before relying on it in
# production.
#
# grpc_health_probe implements gRPC's standard health-checking
# protocol (grpc.health.v1.Health) — must be present on the runner;
# not bundled here.
set -euo pipefail
source "$(dirname "$0")/common.sh"

: "${DeployedJobIds:?DeployedJobIds set by deploy-to-nomad.sh is required}"

overall_status=0

for job_id in ${DeployedJobIds}; do
  service_names="$(nomad job inspect -json "${job_id}" \
    | jq -r '[.Job.TaskGroups[].Services[]?.Name] | unique | .[]')"

  if [ -z "${service_names}" ]; then
    echo "[${job_id}] no Consul services registered by this job — nothing to smoke test."
    continue
  fi

  while IFS= read -r service_name; do
    protocol="$(nomad job inspect -json "${job_id}" \
      | jq -r --arg svc "${service_name}" \
        '[.Job.TaskGroups[].Services[]? | select(.Name == $svc) | .Checks[]?.Type] | first // "http"')"

    if [ "${protocol}" = "grpc" ]; then
      port="$(consul catalog service "${service_name}" -format=json 2>/dev/null | jq -r '.[0].ServicePort')"

      if [ -z "${port}" ] || [ "${port}" = "null" ]; then
        echo "[${job_id}] could not determine port for ${service_name} from Consul catalog." >&2
        overall_status=1
        continue
      fi

      target="${service_name}.service.consul:${port}"
      echo "[${job_id}] smoke testing gRPC health on ${target}..."

      if ! command -v grpc_health_probe &> /dev/null; then
        echo "ERROR: grpc_health_probe not found on this runner." >&2
        overall_status=1
        continue
      fi

      if ! grpc_health_probe -addr="${target}"; then
        echo "[${job_id}] smoke test failed — gRPC health check against ${target} did not report SERVING." >&2
        overall_status=1
      fi
    else
      url="http://${service_name}.service.consul/health"
      echo "[${job_id}] smoke testing ${url}..."
      status_code="$(curl -s -o /dev/null -w '%{http_code}' "${url}" || echo "000")"

      if [ "${status_code}" != "200" ]; then
        echo "[${job_id}] smoke test failed — ${url} returned ${status_code}." >&2
        overall_status=1
      fi
    fi
  done <<< "${service_names}"
done

exit "${overall_status}"