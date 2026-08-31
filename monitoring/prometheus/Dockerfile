FROM prom/prometheus:v2.55.1

COPY prometheus.yaml /etc/prometheus/prometheus.yaml

ENTRYPOINT ["/bin/prometheus"]
CMD ["--config.file=/etc/prometheus/prometheus.yaml", "--storage.tsdb.path=/prometheus"]
