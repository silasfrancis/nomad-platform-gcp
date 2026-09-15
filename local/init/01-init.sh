#!/bin/bash
# init/01-init.sh
#
# PostgreSQL initialisation script — runs automatically inside the platform-db
# container on first startup when the data volume is empty. Mounted into
# /docker-entrypoint-initdb.d/ via docker-compose.yaml.
#
# Creates one user and one database per platform service so each service
# only has credentials for its own database. Passwords are never hardcoded
# here — they are injected at runtime from .env via docker-compose.yaml.
#
# NOTE: this script only runs once. If you change it, destroy the volume
# first: docker compose down -v
set -e

psql -v ON_ERROR_STOP=1 \
  --username "$POSTGRES_USER" \
  --dbname "$POSTGRES_DB" \
  --set=metrics_user="$METRICS_DB_USER" \
  --set=metrics_password="$METRICS_DB_PASSWORD" \
  --set=metrics_db="$METRICS_DB_NAME" \
  --set=sentinel_user="$NOMAD_SENTINEL_DB_USER" \
  --set=sentinel_password="$NOMAD_SENTINEL_DB_PASSWORD" \
  --set=sentinel_db="$NOMAD_SENTINEL_DB_NAME" <<'EOSQL'

CREATE USER :"metrics_user"
  WITH PASSWORD :'metrics_password';

CREATE USER :"sentinel_user"
  WITH PASSWORD :'sentinel_password';

CREATE DATABASE :"metrics_db"
  OWNER :"metrics_user";

CREATE DATABASE :"sentinel_db"
  OWNER :"sentinel_user";

GRANT CONNECT ON DATABASE :"metrics_db"
  TO :"metrics_user";

GRANT CONNECT ON DATABASE :"sentinel_db"
  TO :"sentinel_user";

\connect :"sentinel_db"

GRANT USAGE ON SCHEMA public
  TO :"sentinel_user";

GRANT CREATE ON SCHEMA public
  TO :"sentinel_user";

EOSQL