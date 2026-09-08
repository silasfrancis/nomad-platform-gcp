FROM prom/prometheus:v3.14.0

COPY prometheus.yaml.tmpl /etc/prometheus/prometheus.yaml.tmpl
COPY docker-entrypoint.sh /docker-entrypoint.sh
ENTRYPOINT ["/docker-entrypoint.sh"]