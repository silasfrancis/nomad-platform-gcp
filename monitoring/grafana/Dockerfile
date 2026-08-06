# monitoring/grafana/Dockerfile
#
# Mirrors upstream grafana/grafana into the same registry every other
# image in this project uses, rather than pulling it directly — same
# policy as everything else, applied here too for consistency. Admin
# password is deliberately NOT baked in here — that's a real secret,
# handled at container start by the Ansible role via
# GF_SECURITY_ADMIN_PASSWORD, fetched from Vault at runtime.

FROM grafana/grafana:11.4.0

COPY provisioning/ /etc/grafana/provisioning/
