# CI/CD

Build, security checks, release, and deployment flow using GitHub Actions and Octopus Deploy.

## Repository and branching

The platform uses a trunk-based deployment model with a single `main` branch. Changes are merged into `main`, and the CI pipeline runs from that branch.

The repository contains the application services, monitoring services, and platform Nomad jobs. Change detection determines which items need to be built or released based on the paths configured in `.github/configs/*.json`.

There are no separate development or production branches. The same build produced from `main` is tested in the dev environment and later promoted to prod.

## Pipeline shape

```text
push to main
    │
    ▼
detect-changes.yaml
    │
    ├─► build-services.yaml
    ├─► build-monitoring.yaml
    └─► deploy-platform-jobs.yaml
            │
            ▼
    build-scan-push-sign
            │
       build → Trivy scan → push → Cosign sign + attest
            │
            ▼
      octopus-release
            │
       package → push → create release
            │
            ▼
       Octopus Deploy
            │
       deploy to dev
            │
       test and verify
            │
            ▼
       promote same release
            │
            ▼
       deploy to prod
```

`detect-changes.yaml` is a **reusable workflow** shared by the workflows. It diffs the exact push SHA range against per-item path patterns read from `.github/configs/*.json` (`boutique-services.json`, `monitoring-tools.json`, and `platform-jobs.json`) and only builds items that actually changed.

Each item is built only once. The resulting image, package, and release are then used across environments rather than rebuilding for production.

## Build and release

The build workflows use the shared `build-scan-push-sign` composite action to:

1. Build the image with Docker Buildx.
2. Scan the image with Trivy.
3. Push the image to Artifact Registry.
4. Sign the image with Cosign.
5. Generate and attest the SBOM.
6. Save build metadata.

The `octopus-release` composite action then packages the Nomad job, pushes the package to the Octopus package repository, and creates an Octopus release.

The release number and package version use the same value:

`1.0.0-<name>.<short_sha>`

An Octopus library variable extracts the short SHA from the release number and exposes it as `#{ImageTag}` at deployment time.

## Octopus

Octopus Deploy manages deployment across the environments using its project and lifecycle configuration.

- **5 projects**, one per Nomad namespace (`boutique`, `datastore`, `monitoring`, `operations`, `security`), with `octopus_project` defined in each JSON configuration entry.
- **Lifecycle:** `dev` → `prod`.
- **Dev deployment:** automatic after the release is created.
- **Prod deployment:** requires manual promotion through the Octopus Deploy UI.
- The production deployment uses the **same release and build that was deployed and tested in dev**.
- CPU and memory overrides are resolved inside Octopus rather than being baked into the job spec during the build. Octostache's dynamic indexer syntax, `#{Cpu[#{ServiceName}]}`, is used with `ServiceName` read from the release version.
- One shared variable set is used across the services.

The deployment scripts in `octopus/deployment-scripts/` handle the deployment flow:

```text
validate-nomad-job.sh
        │
        ▼
deploy-to-nomad.sh
        │
        ▼
wait-for-healthy.sh
        │
        ▼
promote-deployment.sh
```

`notify-slack.sh` handles notifications, while `common.sh` contains shared functions.

## Composite actions

The workflows use these reusable composite actions:

| Action | Does |
|---|---|
| `vault-secrets` | Fetches CI secrets from Vault via `hashicorp/vault-action`, authenticated over GitHub OIDC |
| `docker-buildx-setup` | Logs into Artifact Registry and configures Buildx using the `docker-container` driver for GHA cache export |
| `build-scan-push-sign` | Combines image build, scanning, pushing, signing, and attestation |
| `trivy-scan` | Scans images, prints a table on failure, and uploads the report |
| `cosign-sign-attest` | Signs and verifies images and SBOM attestations |
| `octopus-release` | Packages, pushes, and creates the Octopus release |
| `publish-build-manifest` | Writes build metadata to GCS |
| `slack-notify-failure` | Sends failure notifications |

`test-nomad-sentinel.yaml` is a separate reusable `workflow_call` for Nomad dev-mode fixture tests. It is invoked from `build-monitoring.yaml` through a slim `needs`/`if`-only job.

## Runner

The GitHub Actions runner is self-hosted on the management VM and registered using a short-lived token.

The runner authenticates to Vault using GitHub's OIDC token through the `jwt-github-actions` backend. The Vault role is scoped to this repository and `refs/heads/main`, so workflows running from other branches do not match the role.