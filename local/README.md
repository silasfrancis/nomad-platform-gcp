# Local

This directory contains **local development and testing configurations** for the platform.

These files are intended for running platform components locally with Docker Compose and for testing workflows before deploying them to the actual Nomad environment.

## Contents

- `docker-compose.yaml` — Local platform services and supporting infrastructure.
- `docker-compose.services.yaml` — Local application/service definitions.
- `docker-compose-octopus.yaml` — Local Octopus-related testing setup.
- `init/` — PostgreSQL initialization scripts used by the local database.
- `run-sentinel-native.sh` — Helper script for running Nomad Sentinel (the platforms ai monitoring agent) locally.

> **Note:** This directory is for local testing only. Docker Compose is **not** the production deployment platform. Production workloads and platform services are deployed and managed through **Nomad**.