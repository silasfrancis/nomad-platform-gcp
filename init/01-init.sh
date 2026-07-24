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

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" -d "$POSTGRES_DB" <<-EOSQL
    CREATE USER ${METRICS_DB_USER} WITH PASSWORD '${METRICS_DB_PASSWORD}';
    CREATE USER ${NOMAD_SENTINEL_DB_USER} WITH PASSWORD '${NOMAD_SENTINEL_DB_PASSWORD}';

    CREATE DATABASE ${METRICS_DB_NAME} OWNER ${METRICS_DB_USER};
    CREATE DATABASE ${NOMAD_SENTINEL_DB_NAME} OWNER ${NOMAD_SENTINEL_DB_USER};

    GRANT CONNECT ON DATABASE ${METRICS_DB_NAME} TO ${METRICS_DB_USER};
    GRANT CONNECT ON DATABASE ${NOMAD_SENTINEL_DB_NAME} TO ${NOMAD_SENTINEL_DB_USER};

    \c ${NOMAD_SENTINEL_DB_NAME}
    GRANT USAGE ON SCHEMA public TO ${NOMAD_SENTINEL_DB_USER};
    GRANT CREATE ON SCHEMA public TO ${NOMAD_SENTINEL_DB_USER};
EOSQL