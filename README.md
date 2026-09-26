# Nomad Platform on GCP

A workload orchestration platform for running containerized workloads on Google Cloud.

Nomad handles workload orchestration, Consul provides service discovery and service mesh, and Vault manages secrets, workload identity, and dynamic credentials. These three components form the platform's core runtime layer.

Supporting components handle infrastructure provisioning and configuration with Terraform and Ansible, machine image building with Packer, ingress and load balancing with Traefik, and application delivery with Octopus Deploy.

The platform also provides dynamic database credentials, autoscaling, observability, internal and public ingress, PKI and mTLS, runtime security, and backup and restore.

Google's Online Boutique runs as the reference workload, alongside two custom monitoring services built for the platform: `nomad-sentinel` (AI-assisted allocation health analysis and Slack reporting) and `metrics-api` (metrics collection and exposure). Together they exercise the platform's service mesh, discovery, secrets, autoscaling, observability, and deployment flow.

![Architecture](docs/images/platform-architecture.drawio.svg)
*Platform Architecture.*

## Table of Contents

- [Platform Components](#platform-components)
- [Repository Structure](#repository-structure)
- [Getting Started](#getting-started)
  - [1. Bootstrap](#1-bootstrap)
  - [2. Network](#2-network)
  - [3. Build Machine Images](#3-build-machine-images)
  - [4. Generate and Push PKI](#4-generate-and-push-pki)
  - [5. Provision Compute](#5-provision-compute)
  - [6. Configure with Ansible](#6-configure-with-ansible)
  - [7. Configure Core Platform Runtime Services](#7-configure-core-platform-runtime-services)
  - [8. Deploy Cluster Plugins](#8-deploy-cluster-plugins)
  - [9. Deploy Workloads](#9-deploy-workloads)
- [Bringing Your Own Workload](#bringing-your-own-workload)
- [Documentation](#documentation)
- [License](#license)

## Platform components

| Component                    | Implementation                                                                                                       |
| ---------------------------- | -------------------------------------------------------------------------------------------------------------------- |
| **Orchestrator**             | Nomad - dev and prod clusters                                                                                        |
| **Service mesh & discovery** | Consul Connect with service intentions, Consul Catalog                                                               |
| **Secrets**                  | Vault - Workload Identity/JWT auth, dynamic Postgres credentials, GCP secrets backend                                |
| **Autoscaling**              | Nomad Autoscaler - on-demand and spot node pools, driven by Prometheus metrics                                       |
| **CI**                       | GitHub Actions, self-hosted runner                                                                                   |
| **CD**                       | Octopus Deploy (self-hosted)                                                                                         |
| **Ingress**                  | Traefik - 3 VMs, 5 routed instances (public dev, public prod, internal mgmt/dev/prod)                                |
| **PKI**                      | Self-signed, 3 CAs, per-environment leaf certs, mTLS between Nomad/Consul agents                                     |
| **IaC**                      | Terraform, Ansible, Packer (server and client images)                                                                |
| **Observability**            | Prometheus, Loki, Grafana Alloy, Grafana, `nomad-sentinel` (AI-assisted monitoring)                                  |
| **Runtime security**         | Falco with custom rules on Nomad clients, alerts routed to `falco-webhook` service and escalated to `nomad-sentinel` |
| **Backups & recovery**       | Automated daily backups for Vault, Nomad, Consul, Postgres, Octopus MSSQL, with per-component restore scripts        |

## Repo layout

```text
.
├── .github/          # CI: composite actions, config-driven build/deploy workflows
├── ansible/          # Config management - 10 roles, Taskfile-orchestrated
├── docs/             # Documentation
├── local/            # Docker Compose and scripts - local dev/test only
├── monitoring/       # Grafana, Loki, Alloy, Falco webhook, metrics-api, nomad-sentinel
├── nomad-jobs/       # All Nomad job specs, one directory per namespace
├── octopus/          # Octopus worker image + deployment scripts
├── packer/           # Nomad server/client golden image template
├── scripts/          # PKI generation, backup/restore, bootstrap helpers
├── services/         # Google Online Boutique microservices
└── terraform/        # bootstrap → network → compute → platform-config
```

## Getting Started

The platform is deployed in dependency order. Every root terraform module below (`bootstrap`, `network`, `compute`, and each of `platform-config`'s `mgmt`/`dev`/`prod`) uses partial backend configuration, so the first time you touch any of them, initialize it with its own state file before anything else:

```bash
terraform init -backend-config="./state.conf"
```

### 1. Bootstrap

**`terraform/bootstrap`** - project-wide primitives: APIs, KMS, GCS state/artifact buckets, Artifact Registry, service accounts (including Packer's Service Account for building the platform's machine images). Applied once.

### 2. Network

**`terraform/network`** - the VPC, dev/prod/mgmt subnets, firewall rules, Cloud DNS. Packer's build VM lives on `subnet-mgmt`, so this has to exist before step 3.

### 3. Build machine images

**`packer build`** - `terraform/compute` sets `boot_disk_image` to the `nomad-client`/`nomad-server` image families directly; those families don't exist until Packer creates them, and `compute` will fail outright without this step first:

```bash
cd packer && packer init .
packer build -var-file="nomad-server.pkrvars.hcl" .
packer build -var-file="nomad-client.pkrvars.hcl" .
```

One shared template and two variable files, each pointing to an Ansible playbook (`nomad-servers.yaml` / `nomad-clients.yaml`) - see [`packer/README.md`](packer/README.md).

Per-environment values (certificates, gossip keys, and datacenter) are not baked into the images; they're fetched at boot, which is why this step has no dependency on PKI existing yet.

### 4. Generate and push PKI

**`scripts/generate-and-push-pki.sh`** - generates the three CAs and every leaf cert/gossip key, pushes them to Secret Manager.

This must run before step 5's instances actually boot - every startup script fetches its TLS material from Secret Manager with nothing to fall back to.

### 5. Provision compute

**`terraform/compute`** - creates the real VMs/MIGs from the images built in step 3. Instances boot, run their startup scripts, and fetch the PKI material from step 4.

The `active_environments` variable controls which of `dev`/`prod` actually get created - resources for an environment left out aren't stopped, they're never provisioned at all. `mgmt-vm` and `traefik-internal` are unconditional and get created regardless. Defaults to `["dev"]`; add `"prod"` once dev is validated:

```hcl
active_environments    = ["dev", "prod"]
nomad_dev_server_count = 1   # 1-3; prod is always a fixed 3-node Raft cluster
```

Whatever you choose here has to match `mgmt/`'s `nomad_environments` in step 7.

### 6. Configure with Ansible

Export `GCP_PROJECT_ID` once per shell, then run the grouped tasks in order:

```bash
cd ansible
export GCP_PROJECT_ID=<project-id>

task install                # collections + control-node deps
task mgmt-vm                # mgmt (vault, gh runner, octopus deploy), vault-init, grafana - mgmt-vm
task nomad-consul ENV=dev   # consul-acl-bootstrap, nomad-acl-bootstrap - repeat with ENV=prod
task traefik ENV=dev        # traefik-internal, traefik-public - repeat with ENV=prod (traefik-internal re-runs each time, harmless)
```

See [`ansible/Taskfile.yaml`](ansible/Taskfile.yaml) for what each grouped task chains together, and run the individual `task <name> ENV=...` commands instead if you need finer control over a single step.

`nomad-consul` is what pushes the Consul/Nomad operator tokens step 7 needs into Secret Manager.

### 7. Configure core platform runtime services

**`terraform/platform-config`** - Vault engines/policies, Consul/Nomad ACL tokens, Octopus projects and environments, as three independent root modules: `dev/`, `prod/`, and `mgmt/`.

Which environments exist at all is a choice made back in step 5 - `terraform/compute`'s `active_environments` variable controls whether `dev`, `prod`, or both get provisioned. `mgmt/`'s own `nomad_provisioned` / `nomad_environments` variables need to match whatever you actually built.

`dev/` and `prod/` have no dependency on `mgmt/` or on each other - apply either, in any order, whenever its environment exists. `mgmt/`'s `octopus` module normally reads `octopus-deploy-token-{dev,prod}` from Secret Manager, written by each environment's `nomad` module, so it's simplest to apply `dev`/`prod` first. If you need `mgmt/` up before either exists, set `use_dummy_secrets = true` on the `octopus` module instead - it applies with placeholder tokens you fix later, either from the Octopus UI or on a follow-up apply once the real tokens land.

Providers here reach Vault/Octopus/Consul/Nomad through an IAP tunnel to `traefik-internal`, not a public address, so the first time on a given machine:

```bash
cd terraform/platform-config
./scripts/update-hosts.sh   # one-time: follow its printed instructions
```

Then per root module:

```bash
source ./scripts/pre-apply-env.sh <project-id> dev   # exports TF_VAR_consul_token / TF_VAR_nomad_token / TF_VAR_vault_token
./scripts/open-tunnel.sh dev <project-id> <zone>
cd dev && terraform apply
cd .. && ./scripts/close-tunnels.sh
```

Repeat for `prod`, then `mgmt` via `source ./scripts/pre-apply-mgmt.sh <project-id>` (also exports `TF_VAR_vault_token` and `TF_VAR_octopus_api_key`) - see [`terraform/platform-config/README.md`](terraform/platform-config/README.md) for the full dependency notes.

### 8. Deploy cluster plugins

**`nomad-jobs/plugins/deploy-plugins.sh`** - CSI plugin and Autoscaler, deployed directly outside Octopus because these are cluster infrastructure with no real release lifecycle.

### 9. Deploy workloads

Pushes to `main` trigger GitHub Actions. Octopus deploys to dev automatically. The build is promoted to prod after the manual approval gate.

## Bringing your own workload

The platform doesn't care what's running on it - Online Boutique just proves it works. To add your own service:

1. Drop a job spec in `nomad-jobs/<namespace>/` (pick the namespace that fits, or add one).
2. If the job requires a new namespace, add the namespace to `local.namespaces` in `terraform/modules/nomad/locals.tf` before apply.
3. Add that same job to `local.intentions` in `terraform/modules/consul/locals.tf` if it needs to talk to mesh services. Every consul agent has `deny-by-default` enabled so nothing connects until it's listed.
4. If the job needs Vault access, add an entry to `vault_consumers` in `terraform/modules/vault/locals.tf`: the JWT role and any KV/PKI/database access get derived from that entry automatically. The job's `namespace` config is required (it's used for vault's jwt auth `bound_claims`); `kv_paths`, `pki_paths`, and `db_role` are all optional depending on what the job actually needs:

```hcl
   "nomad-sentinel" = {
     namespace = "monitoring"
     kv_paths  = ["nomad-sentinel/config"]
     pki_paths = ["nomad-ca"]
     db_role   = "monitoring"
   }
```

5. Add it to the matching `.github/configs/*.json` so CI picks it up, and give it an Octopus project (or fold it into an existing one) for deployment.

## Documentation

| Doc                                            | Covers                                                                     |
| ---------------------------------------------- | -------------------------------------------------------------------------- |
| [`docs/architecture.md`](docs/architecture.md) | Every layer, with diagrams, and why it's built the way it is               |
| [`docs/security.md`](docs/security.md)         | PKI/mTLS, IAM, secrets tiering, ACL model, supply chain, known limitations |
| [`docs/ci-cd.md`](docs/ci-cd.md)               | The build → scan → sign → release → deploy pipeline in full                |
| [`docs/CHANGELOG.md`](docs/CHANGELOG.md)       | Major redesigns, real bugs fixed, and what's deliberately not implemented  |

## License

MIT - see [`LICENSE`](LICENSE).
