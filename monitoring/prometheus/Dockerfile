# monitoring/prometheus/Dockerfile
#
# Built once, promoted through environments unchanged — same pattern
# as every application service. Scrape targets are baked in via
# Consul service discovery (not static IPs), so the same image works
# for both dev and prod without a rebuild; the only thing that
# differs between them is which Consul cluster this container's local
# agent happens to be talking to at runtime.

FROM prom/prometheus:v2.55.1

COPY prometheus.yml /etc/prometheus/prometheus.yml

ENTRYPOINT ["/bin/prometheus"]
CMD ["--config.file=/etc/prometheus/prometheus.yml", "--storage.tsdb.path=/prometheus"]
