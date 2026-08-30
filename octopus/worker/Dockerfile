# Extends Octopus's own official Tentacle image with the CLI tooling
# our deployment scripts actually call (nomad, consul, jq) — kept in
# its own image rather than baked into octopus-server's own container,
# so bumping the Nomad/Consul CLI version never means rebuilding or
# redeploying the Octopus Server itself.

FROM octopusdeploy/tentacle@sha256:e2fbe3e5e70307d758512eec0a9bf595f30559bd80ab9da8fdb65b2238f84fdf

ARG NOMAD_VERSION=2.0.4
ARG CONSUL_VERSION=2.0.2

RUN apt-get update \
    && apt-get install -y --no-install-recommends curl unzip jq ca-certificates \
    && curl -fsSL "https://releases.hashicorp.com/nomad/${NOMAD_VERSION}/nomad_${NOMAD_VERSION}_linux_amd64.zip" -o /tmp/nomad.zip \
    && unzip -o /tmp/nomad.zip -d /usr/local/bin \
    && rm /tmp/nomad.zip \
    && curl -fsSL "https://releases.hashicorp.com/consul/${CONSUL_VERSION}/consul_${CONSUL_VERSION}_linux_amd64.zip" -o /tmp/consul.zip \
    && unzip -o /tmp/consul.zip -d /usr/local/bin \
    && rm /tmp/consul.zip \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* \
    && nomad -version \
    && consul -version