#!/usr/bin/env bash

###############################################################################
# Nomad Test Jobs Runner
#
# Purpose
# -------
# This script boots a local Nomad dev agent, deploys sample test jobs via the 
# Nomad CLI, gathers status metrics, and handles cleanup or leaves the server 
# and jobs running based on user flags (ideal for CI pipelines).
#
# Usage
# -----
#   ./scripts/run-nomad-test-jobs.sh [--stdout] [--no-cleanup] [--keep-server]
#
#   --stdout:      Prints operational details to stdout instead of storing files.
#   --no-cleanup:  Leaves the deployed jobs running (does not run `nomad job stop`).
#   --keep-server: Leaves the Nomad dev server running in the background.
#
###############################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JOBS_DIR="${SCRIPT_DIR}/test-nomad-jobs"

STDOUT_MODE=false
DO_CLEANUP=true
KEEP_SERVER=false

for arg in "$@"; do
  case "$arg" in
    --stdout) STDOUT_MODE=true ;;
    --no-cleanup) DO_CLEANUP=false ;;
    --keep-server) KEEP_SERVER=true ;;
  esac
done

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
DIR_NAME=$(date +"%Y%m%d-%H%M%S")
OUTPUT_DIR="${SCRIPT_DIR}/output/${DIR_NAME}"

if [[ "$STDOUT_MODE" == "true" ]]; then
  NOMAD_LOG="$(mktemp -d)/nomad.log"
else
  mkdir -p "$OUTPUT_DIR"
  NOMAD_LOG="${OUTPUT_DIR}/nomad.log"
fi

# Job Configuration: Name | File path relative to test-nomad-jobs directory
JOBS=(
  "nginx|nginx.nomad.hcl"
  "crasher|crasher.nomad.hcl"
)

header() { printf "\n# ------------------------------------------------------------------\n# %s\n# ------------------------------------------------------------------\n\n" "$1"; }
check() { printf "✓ %s\n" "$1"; }

# Start the Nomad agent in the background
header "Starting Nomad agent in -dev mode"
nomad agent -dev -bind 0.0.0.0 > "$NOMAD_LOG" 2>&1 &
NOMAD_PID=$!
echo "$NOMAD_PID" > "${SCRIPT_DIR}/.nomad-agent.pid"

export NOMAD_ADDR="http://127.0.0.1:4646"

# Wait for the agent to be ready using Nomad CLI
echo "Waiting for Nomad CLI to connect..."
until nomad node status >/dev/null 2>&1; do
  sleep 1
done
check "Nomad agent is ready (PID: $NOMAD_PID)."

# Deploy Jobs via Nomad CLI
header "Deploying test jobs via Nomad CLI"
for entry in "${JOBS[@]}"; do
  IFS='|' read -r job_name job_file <<< "$entry"
  job_path="${JOBS_DIR}/${job_file}"
  
  if [[ ! -f "$job_path" ]]; then
    echo "Error: Job file not found at $job_path" >&2
    exit 1
  fi

  echo "Submitting ${job_name} using ${job_file}..."
  if [[ "$STDOUT_MODE" == "true" ]]; then
    nomad job run "$job_path"
  else
    nomad job run "$job_path" > "${OUTPUT_DIR}/${job_name}-deploy.log" 2>&1
  fi
  check "Deployed ${job_name}"
done

# Gather Status
header "Collecting job status details"
if [[ "$STDOUT_MODE" == "true" ]]; then
  nomad job status
  nomad alloc status
else
  nomad job status > "${OUTPUT_DIR}/job-status.txt"
  nomad alloc status > "${OUTPUT_DIR}/alloc-status.txt"
  check "Saved CLI status tables to output directory"
fi

echo -e "\nTest jobs orchestration completed successfully."
[[ "$STDOUT_MODE" == "false" ]] && echo "Artifacts stored at: output/${DIR_NAME}"

# Cleanup Handling
cleanup() {
  # 1. Stop Jobs Cleanup
  if [ "$DO_CLEANUP" = true ]; then
    header "Cleaning up: Stopping test jobs"
    for entry in "${JOBS[@]}"; do
      IFS='|' read -r job_name job_file <<< "$entry"
      echo "Stopping job: ${job_name}"
      nomad job stop -purge "$job_name" || true
    done
  else
    echo -e "\nSkipping job cleanup (--no-cleanup flag set). Jobs are left running."
  fi

  # 2. Stop Server Cleanup
  if [ "$KEEP_SERVER" = false ]; then
    echo -e "Stopping Nomad server agent (PID: $NOMAD_PID)..."
    kill "$NOMAD_PID" 2>/dev/null || true
  else
    echo -e "Keeping Nomad server alive in the background (PID: $NOMAD_PID). Remember to stop it manually!"
  fi
}

trap cleanup EXIT