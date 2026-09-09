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

sed \
  -e "s|\${CONSUL_PROMETHEUS_TOKEN}|$CONSUL_PROMETHEUS_TOKEN|g" \
  -e "s|\${CONSUL_SERVER_CA_FILE}|$CONSUL_SERVER_CA_FILE|g" \
  -e "s|\${ENV}|$ENV|g" \
  -e "s|\${TRAEFIK_PUBLIC_IP}|$TRAEFIK_PUBLIC_IP|g" \
  -e "s|\${TRAEFIK_PUBLIC_PORT}|$TRAEFIK_PUBLIC_PORT|g" \
  -e "s|\${TRAEFIK_INTERNAL_IP}|$TRAEFIK_INTERNAL_IP|g" \
  -e "s|\${TRAEFIK_INTERNAL_PORT}|$TRAEFIK_INTERNAL_PORT|g" \
  /etc/prometheus/prometheus.yaml.tmpl > /etc/prometheus/prometheus.yaml

exec /bin/prometheus \
  --config.file=/etc/prometheus/prometheus.yaml \
  "$@"