FROM grafana/loki:3.7.0

COPY loki.yaml /etc/loki/loki.yaml

ENTRYPOINT ["/usr/bin/loki"]

CMD ["-config.file=/etc/loki/loki.yaml", "-config.expand-env=true"]
