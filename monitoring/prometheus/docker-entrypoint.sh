#!/usr/bin/env sh
set -eu

: "${CONSUL_PROMETHEUS_TOKEN:?must be set}"
: "${CONSUL_SERVER_CA_FILE:?must be set}"
: "${ENV:?must be set}"
: "${TRAEFIK_PUBLIC_IP:?must be set}"
: "${TRAEFIK_PUBLIC_PORT:?must be set}"
: "${TRAEFIK_INTERNAL_IP:?must be set}"
: "${TRAEFIK_INTERNAL_PORT:?must be set}"
: "${CONSUL_HTTP_ADDR:?must be set}"

sed \
  -e "s|\${CONSUL_PROMETHEUS_TOKEN}|$CONSUL_PROMETHEUS_TOKEN|g" \
  -e "s|\${CONSUL_SERVER_CA_FILE}|$CONSUL_SERVER_CA_FILE|g" \
  -e "s|\${ENV}|$ENV|g" \
  -e "s|\${TRAEFIK_PUBLIC_IP}|$TRAEFIK_PUBLIC_IP|g" \
  -e "s|\${TRAEFIK_PUBLIC_PORT}|$TRAEFIK_PUBLIC_PORT|g" \
  -e "s|\${TRAEFIK_INTERNAL_IP}|$TRAEFIK_INTERNAL_IP|g" \
  -e "s|\${TRAEFIK_INTERNAL_PORT}|$TRAEFIK_INTERNAL_PORT|g" \
  -e "s|\${CONSUL_HTTP_ADDR}|$CONSUL_HTTP_ADDR|g" \
  /etc/prometheus/prometheus.yaml.tmpl \
  > /etc/prometheus/prometheus.yaml

exec /bin/prometheus \
  --config.file=/etc/prometheus/prometheus.yaml \
  --storage.tsdb.path=/prometheus \
  "$@"