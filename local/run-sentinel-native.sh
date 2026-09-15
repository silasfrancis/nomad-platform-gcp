#!/bin/bash
# local/run-sentinel-native.sh
#
# Runs nomad-sentinel as a native Python process in WSL2.
# Use this instead of the Docker container when running on WSL2, where
# Docker Desktop networking prevents the sentinel container from reaching
# a native Nomad agent on localhost.
#
# Prerequisites:
#   1. Nomad running natively:  nomad agent -dev -bind=0.0.0.0
#   2. DB stack running:        docker compose up -d platform-db
#   3. .env file exists:        cp .env.example .env (and fill in values)
#
# Usage:
#   ./local/run-sentinel-native.sh

set -e

ENV_FILE=".env"
SENTINEL_DIR="monitoring/nomad-sentinel"

if [ ! -f "$ENV_FILE" ]; then
  echo "Error: .env file not found. Run: cp .env.example .env"
  exit 1
fi

# Load .env
set -a
source "$ENV_FILE"
set +a

# Override NOMAD_ADDR and DB port for native mode
# Nomad is on localhost, platform-db is exposed on 5433
export NOMAD_ADDR="http://localhost:4646"
export HISTORY_DATABASE_URL="postgresql://${NOMAD_SENTINEL_DB_USER}:${NOMAD_SENTINEL_DB_PASSWORD}@localhost:5433/${NOMAD_SENTINEL_DB_NAME}"
export HTTP_PORT="${HTTP_PORT:-8092}"
export ENVIRONMENT="local"

echo "Starting nomad-sentinel natively"
echo "  NOMAD_ADDR:  $NOMAD_ADDR"
echo "  HTTP_PORT:   $HTTP_PORT"
echo "  ENVIRONMENT: $ENVIRONMENT"
echo ""
echo "  /health:  http://localhost:${HTTP_PORT}/health"
echo "  /summary: http://localhost:${HTTP_PORT}/summary"
echo ""

cd "$SENTINEL_DIR"

if [ ! -d ".venv" ]; then
  echo "Creating virtualenv..."
  python3 -m venv .venv
fi

source .venv/bin/activate
pip install -q -r requirements.txt

python src/main.py