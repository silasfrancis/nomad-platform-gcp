FROM prom/prometheus:v3.14.0

USER root

RUN apk add --no-cache gettext

COPY prometheus.yaml.tmpl /etc/prometheus/prometheus.yaml.tmpl
COPY --chmod=755 docker-entrypoint.sh /docker-entrypoint.sh

ENTRYPOINT ["/docker-entrypoint.sh"]