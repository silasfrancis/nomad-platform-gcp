#!/usr/bin/env bash
# scripts/restore-postgres.sh
#
# Restores one PostgreSQL database from a pg_dump backup, inside the given
# environment's PostgreSQL Nomad job. Each environment's Postgres instance
# holds TWO databases (§3.1 platform-config decisions): `metrics` (metricsapi's own tables) and `monitoring` (nomad-sentinel's agent_anomalies table).
# They are backed up and restored independently — a bad restore of one must
# never touch the other.
#
# Auth note: this connects as `vault-admin` — a static role the postgres
# Nomad job itself creates via its bootstrap.sql on first init (CREATEROLE,
# owns both `metrics` and `monitoring` outright). This is NOT a dynamic
# Vault database-engine credential — there is no dynamic engine in play
# here, vault-admin already has the privileges a restore needs (drop/
# recreate schema) on both databases it owns. Its password lives in Vault
# KV at kv/data/shared/postgres/admin (vault_admin_password), read fresh
# each run rather than cached.
#
# VAULT_ADDR/VAULT_TOKEN: same shared Vault instance and same
# vault-operator-token (GCP Secret Manager) restore-vault.sh uses — no need
# to export these manually unless overriding for a DR drill.
#
# Reachability: postgres.service.consul is internal-only Consul DNS and has
# no route from outside the VPC. Postgres is reachable from outside only via
# traefik-internal's dedicated TCP passthrough entrypoint (currently
# sslmode=disable / HostSNI(*) — see the pending TLS-passthrough CHANGELOG
# item), at postgres-{env}.platform.lefrancis.org:{15432 dev / 15433 prod}.
# That hostname needs an IAP tunnel into traefik-internal ITSELF first —
# scripts/open-tunnel.sh dev|prod opens both the admin-UI port AND this
# Postgres port together (see preflight_traefik_route in
# lib/restore-common.sh for the exact fallback command if you're not using
# open-tunnel.sh).
#
# Usage:
#   GCP_PROJECT=my-project scripts/restore-postgres.sh --env dev --database metrics

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=lib/restore-common.sh
source lib/restore-common.sh
require_cli vault

TARGET_ENV=""
DATABASE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --env) TARGET_ENV="$2"; shift 2 ;;
    --database) DATABASE="$2"; shift 2 ;;
    --yes) ASSUME_YES=1; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done
require_env "$TARGET_ENV"
case "$DATABASE" in
  metrics|monitoring) ;;
  *) die "--database must be 'metrics' or 'monitoring', got '${DATABASE:-<empty>}'" ;;
esac

confirm_destructive "About to DROP and restore the '$DATABASE' database in the $TARGET_ENV PostgreSQL instance. The other database on the same instance ('$([[ "$DATABASE" == "metrics" ]] && echo monitoring || echo metrics)') is not touched, but metrics-api and/or nomad-sentinel using '$DATABASE' will see connection errors for the duration."

VAULT_ADDR="${VAULT_ADDR:-https://vault.platform.lefrancis.org:8443}"
if [[ -z "${VAULT_TOKEN:-}" ]]; then
  log "VAULT_TOKEN not set — fetching vault-operator-token from GCP Secret Manager"
  VAULT_TOKEN=$(fetch_gcp_secret "vault-operator-token")
fi
export VAULT_ADDR VAULT_TOKEN

PG_HOST="postgres-${TARGET_ENV}.platform.lefrancis.org"   # via traefik-internal's TCP passthrough entrypoint
case "$TARGET_ENV" in
  dev)  DEFAULT_PG_PORT="15432" ;;
  prod) DEFAULT_PG_PORT="15433" ;;
esac
PG_PORT="${PG_PORT:-$DEFAULT_PG_PORT}"

log "checking route to ${PG_HOST}:${PG_PORT} via traefik-internal"
preflight_traefik_route "$PG_HOST" "$PG_PORT"

log "checking route to vault.platform.lefrancis.org:8443 via traefik-internal"
preflight_traefik_route "vault.platform.lefrancis.org" 8443

log "fetching vault-admin Postgres password from Vault"
PGUSER="vault-admin"
PGPASSWORD=$(vault kv get -field=vault_admin_password kv/shared/postgres/admin) \
  || die "could not read vault_admin_password from kv/data/shared/postgres/admin — check the secret still exists at that path"
export PGPASSWORD

backup_file=$(fetch_latest_from_gcs "pg-backups/${TARGET_ENV}/${DATABASE}/" "$SCRATCH_DIR")
log "using backup: $backup_file"

log "terminating existing connections to '$DATABASE' before restore"
psql -h "$PG_HOST" -p "$PG_PORT" -U "$PGUSER" -d postgres -v ON_ERROR_STOP=1 -c \
  "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '${DATABASE}' AND pid <> pg_backend_pid();" \
  || die "could not terminate existing connections — check connectivity to ${PG_HOST}:${PG_PORT} first"

log "dropping and recreating '$DATABASE'"
psql -h "$PG_HOST" -p "$PG_PORT" -U "$PGUSER" -d postgres -v ON_ERROR_STOP=1 -c "DROP DATABASE IF EXISTS ${DATABASE};" \
  && psql -h "$PG_HOST" -p "$PG_PORT" -U "$PGUSER" -d postgres -v ON_ERROR_STOP=1 -c "CREATE DATABASE ${DATABASE};" \
  || die "drop/recreate failed"

log "restoring dump into '$DATABASE'"
gunzip -c "$backup_file" | psql -h "$PG_HOST" -p "$PG_PORT" -U "$PGUSER" -d "$DATABASE" -v ON_ERROR_STOP=1 \
  || die "restore failed partway through — '$DATABASE' is now in an inconsistent state, do not let workloads reconnect until this is resolved"

log "restore complete. Verification:"
if [[ "$DATABASE" == "metrics" ]]; then
  cat <<EOF
  # metrics-api itself is internal-only (Consul DNS) — run this from inside
  # the VPC, or via the IAP tunnel to traefik-internal if it's ever fronted:
  curl -s http://metrics-api.service.consul:8080/db-check | jq
EOF
else
  cat <<EOF
  psql -h $PG_HOST -p $PG_PORT -U $PGUSER -d monitoring -c "SELECT count(*), max(detected_at) FROM agent_anomalies;"
EOF
fi
log "done."
