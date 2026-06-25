#!/usr/bin/env bash

###############################################################################
# Nomad API Reference Collection Script
#
# Purpose
# -------
# Creates sample Nomad jobs and collects real API responses that can be used
# for:
#
#   - AI agent testing
#   - Prompt engineering
#   - CI/CD validation
#   - Integration testing
#   - Nomad API exploration
#   - Building RAG datasets
#
#
# Features
# --------
# - Creates nginx and crasher jobs
# - Dynamically discovers allocation IDs
# - Collects allocation details, stats, logs, nodes and evaluations
# - Supports stdout mode (CI-friendly)
# - Supports file mode (reference dataset generation)
# - Handles empty log responses
# - Avoids jq argument size limitations
# - Works with changing allocation/evaluation IDs
#
#
# Usage
# -----
#
# Save responses to files:
#
#   ./collect-nomad-data.sh
#
# Custom Nomad address:
#
#   ./collect-nomad-data.sh http://10.0.0.5:4646
#
# Print responses to stdout (CI mode):
#
#   ./collect-nomad-data.sh --stdout
#
# Custom address + stdout:
#
#   ./collect-nomad-data.sh http://10.0.0.5:4646 --stdout
#
#
# Output Structure
# ----------------
#
# scripts/output/<timestamp>/
#
#   create-nginx-job.json
#   create-crasher-job.json
#
#   jobs.json
#   job-nginx.json
#   job-crasher.json
#
#   job-nginx-allocations.json
#   job-crasher-allocations.json
#
#   allocation-nginx.json
#   allocation-crasher.json
#
#   allocation-nginx-stats.json
#   allocation-crasher-stats.json
#
#   allocation-nginx-stdout.json
#   allocation-nginx-stderr.json
#
#   allocation-crasher-stdout.json
#   allocation-crasher-stderr.json
#
#   nodes.json
#   node.json
#
#   evaluation-nginx.json
#   evaluation-crasher.json
#
#   endpoints.txt
#
###############################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

NOMAD_ADDR="http://localhost:4646"
STDOUT_MODE=false

for arg in "$@"; do
  case "$arg" in
    --stdout)
      STDOUT_MODE=true
      ;;
    http://*|https://*)
      NOMAD_ADDR="$arg"
      ;;
  esac
done

TIMESTAMP=$(date +"%Y%m%d-%H%M%S")
OUTPUT_DIR="${SCRIPT_DIR}/output/${TIMESTAMP}"

if [[ "$STDOUT_MODE" == "false" ]]; then
  mkdir -p "$OUTPUT_DIR"
fi

###############################################################################
# Helpers
###############################################################################

save_response() {
  local METHOD="$1"
  local URL="$2"
  local OUTPUT_FILE="$3"
  local PAYLOAD_FILE="${4:-}"

  local RESPONSE_FILE
  RESPONSE_FILE=$(mktemp)

  if [[ -n "$PAYLOAD_FILE" ]]; then
    curl -s \
      -X "$METHOD" \
      -H "Content-Type: application/json" \
      --data @"$PAYLOAD_FILE" \
      "$URL" \
      > "$RESPONSE_FILE"
  else
    curl -s \
      -X "$METHOD" \
      "$URL" \
      > "$RESPONSE_FILE"
  fi

  {
    echo "{"
    echo "  \"timestamp\": \"$(date -Iseconds)\","
    echo "  \"method\": \"$METHOD\","
    echo "  \"endpoint\": \"$URL\","

    if [[ -n "$PAYLOAD_FILE" ]]; then
      echo "  \"payload\":"
      cat "$PAYLOAD_FILE"
      echo ","
    else
      echo "  \"payload\": null,"
    fi

    echo "  \"response\":"
    cat "$RESPONSE_FILE"
    echo "}"
  } > "$OUTPUT_FILE"

  rm -f "$RESPONSE_FILE"
}

print_response() {
  local METHOD="$1"
  local URL="$2"
  local PAYLOAD_FILE="${3:-}"

  local RESPONSE_FILE
  RESPONSE_FILE=$(mktemp)

  if [[ -n "$PAYLOAD_FILE" ]]; then
    curl -s \
      -X "$METHOD" \
      -H "Content-Type: application/json" \
      --data @"$PAYLOAD_FILE" \
      "$URL" \
      > "$RESPONSE_FILE"
  else
    curl -s \
      -X "$METHOD" \
      "$URL" \
      > "$RESPONSE_FILE"
  fi

  echo
  echo "================================================================="
  echo "$METHOD $URL"
  echo "================================================================="

  cat <<EOF
{
  "timestamp": "$(date -Iseconds)",
  "method": "$METHOD",
  "endpoint": "$URL",
  "payload":
EOF

  if [[ -n "$PAYLOAD_FILE" ]]; then
    cat "$PAYLOAD_FILE"
  else
    echo "null"
  fi

  echo ","
  echo "\"response\":"

  cat "$RESPONSE_FILE"

  echo
  echo "}"
  echo

  rm -f "$RESPONSE_FILE"
}

save_log() {
  local URL="$1"
  local OUTPUT_FILE="$2"

  local RESPONSE
  RESPONSE=$(curl -s "$URL" || true)

  [[ -z "$RESPONSE" ]] && RESPONSE="NO_LOG_OUTPUT"

  {
    echo "{"
    echo "  \"timestamp\": \"$(date -Iseconds)\","
    echo "  \"method\": \"GET\","
    echo "  \"endpoint\": \"$URL\","
    echo "  \"payload\": null,"
    echo "  \"response\":"
    jq -Rn --arg text "$RESPONSE" '$text'
    echo "}"
  } > "$OUTPUT_FILE"
}

run_request() {
  local METHOD="$1"
  local URL="$2"
  local OUTPUT_FILE="$3"
  local PAYLOAD_FILE="${4:-}"

  if [[ "$STDOUT_MODE" == "true" ]]; then
    print_response "$METHOD" "$URL" "$PAYLOAD_FILE"
  else
    save_response "$METHOD" "$URL" "$OUTPUT_FILE" "$PAYLOAD_FILE"
  fi
}

###############################################################################
# Create Jobs
###############################################################################

echo "Creating nginx job..."

run_request \
  POST \
  "${NOMAD_ADDR}/v1/jobs" \
  "${OUTPUT_DIR}/create-nginx-job.json" \
  "${SCRIPT_DIR}/nginx-job.json"

echo "Creating crasher job..."

run_request \
  POST \
  "${NOMAD_ADDR}/v1/jobs" \
  "${OUTPUT_DIR}/create-crasher-job.json" \
  "${SCRIPT_DIR}/crasher-job.json"

echo "Waiting for allocations..."
sleep 10

###############################################################################
# Fetch allocations separately for ID discovery
###############################################################################

NGINX_ALLOCATIONS=$(mktemp)
CRASHER_ALLOCATIONS=$(mktemp)

curl -s \
  "${NOMAD_ADDR}/v1/job/nginx/allocations" \
  > "$NGINX_ALLOCATIONS"

curl -s \
  "${NOMAD_ADDR}/v1/job/crasher/allocations" \
  > "$CRASHER_ALLOCATIONS"

NGINX_ALLOC_ID=$(jq -r '.[0].ID' "$NGINX_ALLOCATIONS")
CRASHER_ALLOC_ID=$(jq -r '.[0].ID' "$CRASHER_ALLOCATIONS")

echo "NGINX_ALLOC_ID=${NGINX_ALLOC_ID}"
echo "CRASHER_ALLOC_ID=${CRASHER_ALLOC_ID}"

###############################################################################
# Jobs
###############################################################################

run_request GET "${NOMAD_ADDR}/v1/jobs" \
  "${OUTPUT_DIR}/jobs.json"

run_request GET "${NOMAD_ADDR}/v1/job/nginx" \
  "${OUTPUT_DIR}/job-nginx.json"

run_request GET "${NOMAD_ADDR}/v1/job/crasher" \
  "${OUTPUT_DIR}/job-crasher.json"

###############################################################################
# Allocations
###############################################################################

run_request GET "${NOMAD_ADDR}/v1/job/nginx/allocations" \
  "${OUTPUT_DIR}/job-nginx-allocations.json"

run_request GET "${NOMAD_ADDR}/v1/job/crasher/allocations" \
  "${OUTPUT_DIR}/job-crasher-allocations.json"

run_request GET "${NOMAD_ADDR}/v1/allocation/${NGINX_ALLOC_ID}" \
  "${OUTPUT_DIR}/allocation-nginx.json"

run_request GET "${NOMAD_ADDR}/v1/allocation/${CRASHER_ALLOC_ID}" \
  "${OUTPUT_DIR}/allocation-crasher.json"

###############################################################################
# Stats
###############################################################################

run_request GET \
  "${NOMAD_ADDR}/v1/client/allocation/${NGINX_ALLOC_ID}/stats" \
  "${OUTPUT_DIR}/allocation-nginx-stats.json"

run_request GET \
  "${NOMAD_ADDR}/v1/client/allocation/${CRASHER_ALLOC_ID}/stats" \
  "${OUTPUT_DIR}/allocation-crasher-stats.json"

###############################################################################
# Logs
###############################################################################

if [[ "$STDOUT_MODE" == "false" ]]; then

  save_log \
    "${NOMAD_ADDR}/v1/client/fs/logs/${NGINX_ALLOC_ID}?task=nginx&type=stdout&plain=true" \
    "${OUTPUT_DIR}/allocation-nginx-stdout.json"

  save_log \
    "${NOMAD_ADDR}/v1/client/fs/logs/${NGINX_ALLOC_ID}?task=nginx&type=stderr&plain=true" \
    "${OUTPUT_DIR}/allocation-nginx-stderr.json"

  save_log \
    "${NOMAD_ADDR}/v1/client/fs/logs/${CRASHER_ALLOC_ID}?task=app&type=stdout&plain=true" \
    "${OUTPUT_DIR}/allocation-crasher-stdout.json"

  save_log \
    "${NOMAD_ADDR}/v1/client/fs/logs/${CRASHER_ALLOC_ID}?task=app&type=stderr&plain=true" \
    "${OUTPUT_DIR}/allocation-crasher-stderr.json"

fi

###############################################################################
# Nodes
###############################################################################

NODES_FILE=$(mktemp)

curl -s \
  "${NOMAD_ADDR}/v1/nodes" \
  > "$NODES_FILE"

NODE_ID=$(jq -r '.[0].ID' "$NODES_FILE")

run_request GET \
  "${NOMAD_ADDR}/v1/nodes" \
  "${OUTPUT_DIR}/nodes.json"

run_request GET \
  "${NOMAD_ADDR}/v1/node/${NODE_ID}" \
  "${OUTPUT_DIR}/node.json"

###############################################################################
# Evaluations
###############################################################################

ALLOC_NGINX=$(mktemp)
ALLOC_CRASHER=$(mktemp)

curl -s \
  "${NOMAD_ADDR}/v1/allocation/${NGINX_ALLOC_ID}" \
  > "$ALLOC_NGINX"

curl -s \
  "${NOMAD_ADDR}/v1/allocation/${CRASHER_ALLOC_ID}" \
  > "$ALLOC_CRASHER"

NGINX_EVAL_ID=$(jq -r '.EvalID' "$ALLOC_NGINX")
CRASHER_EVAL_ID=$(jq -r '.EvalID' "$ALLOC_CRASHER")

run_request GET \
  "${NOMAD_ADDR}/v1/evaluation/${NGINX_EVAL_ID}" \
  "${OUTPUT_DIR}/evaluation-nginx.json"

run_request GET \
  "${NOMAD_ADDR}/v1/evaluation/${CRASHER_EVAL_ID}" \
  "${OUTPUT_DIR}/evaluation-crasher.json"

###############################################################################
# Endpoint Index
###############################################################################

if [[ "$STDOUT_MODE" == "false" ]]; then

cat > "${OUTPUT_DIR}/endpoints.txt" <<EOF
GET /v1/jobs
GET /v1/job/nginx
GET /v1/job/crasher

GET /v1/job/nginx/allocations
GET /v1/job/crasher/allocations

GET /v1/allocation/${NGINX_ALLOC_ID}
GET /v1/allocation/${CRASHER_ALLOC_ID}

GET /v1/client/allocation/${NGINX_ALLOC_ID}/stats
GET /v1/client/allocation/${CRASHER_ALLOC_ID}/stats

GET /v1/nodes
GET /v1/node/${NODE_ID}

GET /v1/evaluation/${NGINX_EVAL_ID}
GET /v1/evaluation/${CRASHER_EVAL_ID}
EOF

fi

rm -f \
  "$NGINX_ALLOCATIONS" \
  "$CRASHER_ALLOCATIONS" \
  "$NODES_FILE" \
  "$ALLOC_NGINX" \
  "$ALLOC_CRASHER"

echo
echo "Done."

if [[ "$STDOUT_MODE" == "false" ]]; then
  echo "Output directory:"
  echo "$OUTPUT_DIR"
fi