#!/usr/bin/env sh
# docker-entrypoint.sh
set -eu

# Fail fast with a clear error if a required var is missing, rather than
# silently rendering an empty string into the config.
: "${CONSUL_PROMETHEUS_TOKEN:?must be set}"
: "${CONSUL_SERVER_CA_FILE:?must be set}"
: "${ENV:?must be set}"
: "${TRAEFIK_PUBLIC_IP:?must be set}"
: "${TRAEFIK_PUBLIC_PORT:?must be set}"
: "${TRAEFIK_INTERNAL_IP:?must be set}"
: "${TRAEFIK_INTERNAL_PORT:?must be set}"


envsubst '${CONSUL_PROMETHEUS_TOKEN} ${CONSUL_SERVER_CA_FILE} ${ENV} ${TRAEFIK_PUBLIC_IP} ${TRAEFIK_PUBLIC_PORT} ${TRAEFIK_INTERNAL_IP} ${TRAEFIK_INTERNAL_PORT}' \
  < /etc/prometheus/prometheus.yaml.tmpl > /etc/prometheus/prometheus.yaml

exec /bin/prometheus \
  --config.file=/etc/prometheus/prometheus.yaml \
  "$@"