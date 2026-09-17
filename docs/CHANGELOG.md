# Changelog

## v1.0.0 — Initial release

Initial platform release covering the components documented in [`docs/architecture.md`](architecture.md).

### Infrastructure

- Four-layer Terraform pipeline (`bootstrap` → `network` → `compute` → `platform-config`), each with its own state, chained via `terraform_remote_state`.
- One VPC, three-subnet design (`mgmt`, `dev`, `prod`), with dev/prod further split into private/public CIDR ranges.
- IAP-only administrative access — no public IP on any VM except the two public Traefik instances.
- Packer-built golden images for both Nomad server and client roles, from one shared template.
- 10-role Ansible codebase, orchestrated by a single `Taskfile.yaml`.

### Orchestration & autoscaling

- Nomad (Community Edition), dev and prod environments, six namespaces mapped to Consul ACL scope and Octopus projects.
- Consul Connect service mesh, deny-by-default intentions.
- Nomad Autoscaler managing node count per pool (on-demand/spot, per environment), with allocation-aware drain-before-terminate scale-in.
- Horizontal task-count scaling on `frontend`, using the same Autoscaler agent.

### Secrets & PKI

- Vault with Workload Identity/JWT authentication for every Nomad task that needs it — no static long-lived application tokens.
- Dynamic, per-lease Postgres credentials for `metrics-api` and `nomad-sentinel`.
- GitHub OIDC straight into Vault for CI — no long-lived GitHub secret exists anywhere in the pipeline.
- Fully self-signed PKI: three CAs, mTLS on every Nomad/Consul connection, one script (`generate-and-push-pki.sh`) generating and distributing all of it.
- Four-tier GCP Secret Manager model (`root`/`operator`/`mgmt`/`scoped`), CMEK across Secret Manager, GCS, and Artifact Registry.

### Ingress

- Public ingress (Traefik, HTTP-01, Consul-Catalog-only, tag-gated) fully separated from internal ingress (Traefik, DNS-01, no public IP, IAP tunnel only).
- Single internal ingress point (`traefik-internal`) running three isolated Traefik processes (`mgmt`, `dev-internal`, `prod-internal`), the one deliberate, narrowly-scoped crossing of the dev/prod firewall boundary.
- One private Cloud DNS zone resolving every internal platform hostname.
- Dedicated TCP passthrough entrypoints for Postgres, per environment.

### CI/CD

- GitHub Actions: config-driven build matrix, Trivy scan, Cosign sign + SBOM attestation, all external actions pinned by commit SHA.
- Octopus Deploy (self-hosted): 5 projects mapped to Nomad namespaces, dev → prod promotion with a manual approval gate, canary deployments with health-gated auto-promotion.
- Self-hosted GitHub Actions runner, registered with a short-lived token, authenticating to Vault via OIDC.

### Observability & runtime security

- Prometheus (Consul-catalog discovery), Loki + Grafana Alloy for logs, Grafana for dashboards (image-baked, no persistent disk needed).
- `nomad-sentinel`: AI-assisted allocation-health monitoring and Slack alerting on top of the platform's own telemetry.
- Falco on every Nomad client with 5 custom rules, feeding a webhook receiver that escalates into the same AI-assisted triage loop.

### Backup & restore

- Daily automated backups for Vault, Consul, Postgres, and Octopus, each to a CMEK-encrypted GCS bucket with 90-day retention.
- A purpose-written restore script per component, accounting for how each one actually needs to be restored — including Nomad's Workload Identity keyring preservation.

---

Known limitations and planned improvements beyond this release are tracked in [`docs/architecture.md`](architecture.md#known-limitations).
