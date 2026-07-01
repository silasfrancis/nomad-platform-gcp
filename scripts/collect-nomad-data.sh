#!/usr/bin/env bash

###############################################################################
# Nomad API Reference Collector
#
# Purpose
# -------
# This script deploys sample Nomad jobs and collects API responses into a
# structured JSON format for use in AI agents, RAG datasets, or CI testing.
#
# Usage
# -----
#   ./scripts/collect-nomad-data.sh [NOMAD_URL] [--stdout]
#
#   - NOMAD_URL: Optional. Default is http://localhost:4646
#   - --stdout:  Optional. Prints JSON to terminal instead of saving files.
# 
# Job Configuration
# -----------------
# Jobs are defined in the JOBS array using the format:
#
#   JOB_NAME | PAYLOAD_FILE | TASK_NAME
#
# Example:
#   JOBS=(
#     "nginx|nginx-job.json|nginx"
#     "crasher|crasher-job.json|app"
#   )
#
# Where:
#   JOB_NAME: The Nomad job name.
#   PAYLOAD_FILE: The job specification file located in the same directory as this script.
#   TASK_NAME: The task name inside the Nomad job. This is used when collecting
#       stdout and stderr logs from the allocation.
#
# To add another sample job, simply add another entry to the JOBS array.
# No other part of the script needs to be modified.
# 
# Output Format
# -------------
# Each request is logged as a JSON object containing:
#   - schema_version, timestamp, method, endpoint, status_code, body_type, response
#
# Configuration
# -------------
# Jobs are defined in the JOBS array: "JOB_NAME|PAYLOAD_FILE|TASK_NAME"
#
###############################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NOMAD_ADDR="http://localhost:4646"
STDOUT_MODE=false
DO_CLEANUP=true

for arg in "$@"; do
  case "$arg" in
    --stdout) STDOUT_MODE=true ;;
    http://*|https://*) NOMAD_ADDR="$arg" ;;
  esac
done

for arg in "$@"; do
  if [ "$arg" == "--no-cleanup" ]; then
    DO_CLEANUP=false
  fi
done


TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
DIR_NAME=$(date +"%Y%m%d-%H%M%S")
OUTPUT_DIR="${SCRIPT_DIR}/output/${DIR_NAME}"
[[ "$STDOUT_MODE" == "false" ]] && mkdir -p "$OUTPUT_DIR"

# Job Configuration
# jobname | payload | task name
JOBS=(
  "nginx|nginx-job.json|nginx"
  "crasher|crasher-job.json|app"
)

declare -A ALLOC_IDS
declare -A EVAL_IDS

# Start the Nomad agent in the background
echo "Starting Nomad agent in -dev mode..."
nomad agent -dev -bind 0.0.0.0 > "${OUTPUT_DIR}/nomad.log" 2>&1 &
NOMAD_PID=$!

# Wait for the agent to be ready
echo "Waiting for Nomad to start..."
until curl -s "${NOMAD_ADDR}/v1/agent/health" | grep -q '"ok":true'; do
  sleep 1
done
echo "Nomad agent is ready (PID: $NOMAD_PID)."

# Function to perform requests and save in requested schema
structured_request() {
  local method="$1" endpoint="$2" outfile="$3" payload="${4:-}"
  local tmp_resp; tmp_resp=$(mktemp)
  local req_ts; req_ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  
  local curl_args=(-s -w "%{http_code}" -o "$tmp_resp" -X "$method")
  if [[ -n "$payload" ]]; then
    curl_args+=(-H "Content-Type: application/json" --data @"$payload")
  fi
  
  local status_code; status_code=$(curl "${curl_args[@]}" "${NOMAD_ADDR}${endpoint}" 2>/dev/null || echo "000")
  
  local response_bytes; response_bytes=$(wc -c < "$tmp_resp")
  local success=false
  [[ "$status_code" =~ ^2[0-9][0-9]$ ]] && success=true
  
  # Response processing
  local final_json
  final_json=$(
    cat "$tmp_resp" | jq -R -s \
      --arg sv "1" \
      --arg ts "$req_ts" \
      --arg m "$method" \
      --arg e "$endpoint" \
      --argjson sc "$status_code" \
      --argjson succ "$success" \
      --arg bt "$(file -b --mime-type "$tmp_resp")" \
      --argjson rb "$response_bytes" \
      '{schema_version: ($sv|tonumber), timestamp: $ts, method: $m, endpoint: $e, status_code: $sc, success: $succ, body_type: $bt, response_bytes: $rb, response: (fromjson? // .)}'
  )

  if [[ "$STDOUT_MODE" == "true" ]]; then echo "$final_json"; else echo "$final_json" > "$outfile"; fi
  rm -f "$tmp_resp"
}

# Formatting Helpers
header() { printf "\n# ------------------------------------------------------------------\n# %s\n# ------------------------------------------------------------------\n\n" "$1"; }
check() { printf "✓ %s\n" "$1"; }

# Creating sample jobs
header "Creating sample jobs"
for entry in "${JOBS[@]}"; do
  IFS='|' read -r job payload task <<< "$entry"
  echo "Creating ${job}..."
  structured_request POST "/v1/jobs" "${OUTPUT_DIR}/${job}-job-create.json" "${SCRIPT_DIR}/${payload}"
  EVAL_IDS["$job"]="$(jq -r '.response.EvalID' "${OUTPUT_DIR}/${job}-job-create.json" 2>/dev/null || echo "")"
  check "Created"
done

# Waiting for allocations
header "Waiting for allocations"
for entry in "${JOBS[@]}"; do
  IFS='|' read -r job payload task <<< "$entry"
  echo "Waiting for ${job} allocation..."
  while true; do
    id=$(curl -s "${NOMAD_ADDR}/v1/job/${job}/allocations" | jq -r 'first(.[]?.ID)//empty')
    if [[ -n "$id" ]]; then ALLOC_IDS["$job"]="$id"; check "Allocation: ${id:0:8}..."; break; fi
    sleep 1
  done
done

# Collecting cluster information
header "Collecting cluster information"
structured_request GET "/v1/jobs" "${OUTPUT_DIR}/jobs.json"; check "Jobs"
structured_request GET "/v1/allocations" "${OUTPUT_DIR}/allocations.json"; check "Allocations"

# Collecting allocation statistics
header "Collecting allocation statistics"
for job in "${!ALLOC_IDS[@]}"; do
  structured_request GET "/v1/client/allocation/${ALLOC_IDS[$job]}/stats" "${OUTPUT_DIR}/stats-${job}.json"
  check "${job} stats"
done

# Collecting stdout logs
header "Collecting stdout logs"
for entry in "${JOBS[@]}"; do
  IFS='|' read -r job payload task <<< "$entry"
  structured_request GET "/v1/client/fs/logs/${ALLOC_IDS[$job]}?task=${task}&type=stdout&plain=true" "${OUTPUT_DIR}/${job}-stdout.json"
  check "${job} stdout"
done

# Collecting stderr logs
header "Collecting stderr logs"
for entry in "${JOBS[@]}"; do
  IFS='|' read -r job payload task <<< "$entry"
  structured_request GET "/v1/client/fs/logs/${ALLOC_IDS[$job]}?task=${task}&type=stderr&plain=true" "${OUTPUT_DIR}/${job}-stderr.json"
  check "${job} stderr"
done

# Collecting evaluations
header "Collecting evaluations"
for job in "${!EVAL_IDS[@]}"; do
  structured_request GET "/v1/evaluation/${EVAL_IDS[$job]}" "${OUTPUT_DIR}/eval-${job}.json"
  check "${job} evaluation"
done

# Collecting node information
header "Collecting node information"
structured_request GET "/v1/nodes" "${OUTPUT_DIR}/nodes.json"; check "Nodes"
NODE_ID=$(jq -r '.response[0].ID' "${OUTPUT_DIR}/nodes.json")
structured_request GET "/v1/node/${NODE_ID}" "${OUTPUT_DIR}/node.json"; check "Node details"

echo -e "\nDone.\n\nOutput:\noutput/${DIR_NAME}"

# Cleanup: Stop the agent when finished or on error
cleanup() {
  if [ "$DO_CLEANUP" = true ]; then
    echo -e "\nCleaning up: Stopping Nomad agent (PID: $NOMAD_PID)..."
    kill "$NOMAD_PID"
  else
    echo -e "\nSkipping cleanup as requested."
  fi
}

trap cleanup EXIT