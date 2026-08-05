# monitoring/alloy/Dockerfile
FROM grafana/alloy:v1.5.1

COPY config.alloy /etc/alloy/config.alloy

ENTRYPOINT ["/bin/alloy"]
CMD ["run", "/etc/alloy/config.alloy"]
