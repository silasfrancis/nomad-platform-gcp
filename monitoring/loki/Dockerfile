# monitoring/loki/Dockerfile
FROM grafana/loki:3.3.2

COPY loki.yml /etc/loki/loki.yml

ENTRYPOINT ["/usr/bin/loki"]
CMD ["-config.file=/etc/loki/loki.yml"]
