# CI/CD

Build, security checks, release, and deployment flow using GitHub Actions and Octopus Deploy.

## Pipeline shape

```
push to main
    │
    ▼
detect-changes.yaml ──► matrix of changed items (name, path, job_spec, octopus_project)
    │
    ├─► build-services.yaml ────┐
    ├─► build-monitoring.yaml ──┤──► build-scan-push-sign (composite)
    └─► deploy-platform-jobs.yaml┘
                                 │
                    buildx → build → Trivy scan → push → Cosign sign+attest → save metadata
                                 │
                                 ▼
                        octopus-release (composite)
                                 │
                    package → push → create release → deploy to dev (auto) → prod (manual gate)
```

`detect-changes.yaml` is a **reusable workflow**, and shared by the workflows — it diffs the exact push SHA range against per-item path patterns read from `.github/configs/*.json` (`boutique-services.json`, `monitoring-tools.json`, `platform-jobs.json`), and only builds what actually changed.

## Composite actions

The workflows use these reusable composite actions:

| Action | Does |
|---|---|
| `vault-secrets` | Fetches CI secrets from Vault via `hashicorp/vault-action`, authenticated over GitHub OIDC |
| `docker-buildx-setup` | Artifact Registry login + `setup-buildx-action` (the `docker-container` driver, needed for GHA cache export) |
| `build-scan-push-sign` | Combines the build, scan, push, and signing steps |
| `trivy-scan` | Scans images, prints a table on failure, and uploads the report |
| `cosign-sign-attest` | Signs and verifies images and SBOM attestations |
| `octopus-release` | Package, zip, push, create release |
| `publish-build-manifest` | Writes build metadata to GCS |
| `slack-notify-failure` | Sends failure notifications |

`test-nomad-sentinel.yaml` is its own reusable `workflow_call` (Nomad dev-mode fixture tests), invoked from `build-monitoring.yaml` via a slim `needs`/`if`-only job.

## Versioning

`package-version` and `release-number` are the **same value**: `1.0.0-<name>.<short_sha>` — valid SemVer pre-release syntax, so package and release versions remain the same. An Octopus library variable strips everything up to the last dot to recover the short SHA as `#{ImageTag}` at deploy time.

## Octopus

- **5 projects**, one per Nomad namespace (`boutique`, `datastore`, `monitoring`, `operations`, `security`) with `octopus_project` in each JSON configuration entry.
- **Lifecycle**: `dev` → `prod`, manual approval gate before prod.
- **CPU/memory overrides are resolved inside Octopus itself**, not baked into the job spec at build time — via Octostache's dynamic indexer syntax, `#{Cpu[#{ServiceName}]}`, with `ServiceName` read from the release version. One shared variable set is used for all services.
- **Deployment scripts** (`octopus/deployment-scripts/`): `validate-nomad-job.sh` → `deploy-to-nomad.sh` → `wait-for-healthy.sh` → `promote-deployment.sh`, with `notify-slack.sh` on the way out. `common.sh` contains shared functions.

## Runner

Self-hosted, on the management VM, registered with a short-lived token. Authenticates to Vault via GitHub's own OIDC token (`jwt-github-actions` backend), scoped to this repo and `refs/heads/main` — runs from other branches do not match this Vault role.
