FROM prom/prometheus:v3.14.0

USER root

COPY prometheus.yaml.tmpl /etc/prometheus/prometheus.yaml.tmpl
COPY --chmod=755 docker-entrypoint.sh /docker-entrypoint.sh

RUN chown nobody:nobody /etc/prometheus

USER nobody

ENTRYPOINT ["/docker-entrypoint.sh"]