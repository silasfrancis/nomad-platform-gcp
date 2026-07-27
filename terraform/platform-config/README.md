# platform-config

Four modules under `modules/` (`vault`, `octopus`, `consul`, `nomad`) —
the actual resource logic, environment-agnostic where possible,
parameterized by `var.environment` where it matters. Three root
directories call them: `mgmt/` (Vault + Octopus — single instances,
serve both environments internally), `dev/`, and `prod/` (Consul +
Nomad — two genuinely separate clusters, one directory each). Each root
directory is its own state file, its own backend prefix, its own
`terraform apply`.

## Why three roots, not one combined apply

Consul and Nomad dev/prod are two independent, non-federated
clusters with different credentials and different CA-signed cert
chains — HashiCorp's own guidance is that workspaces aren't the right
tool for that kind of separation (shared backend, shared code, easy to
apply against the wrong one without noticing). Separate directories
mean you can only ever be standing in one environment at a time —
`cd dev` vs `cd prod` is visible in your shell, unlike an invisible
`terraform workspace select`.

## Apply order

`dev/` and `prod/` have **zero dependency on `mgmt/`** — apply either
in any order, independently, any time.

`mgmt/` has **one** dependency: it reads `octopus-deploy-token-{dev,prod}`
from Secret Manager, written by `dev/`'s and `prod/`'s `nomad` module.
So `dev/` and `prod/` must each be applied **at least once** before
`mgmt/`'s first successful apply. After that, all three are independent
of each other on every subsequent apply.

```
source ./scripts/pre-apply-env.sh <project-id> dev
./scripts/open-tunnel.sh dev <project-id> <zone>
cd dev && terraform apply
cd .. && ./scripts/close-tunnels.sh

source ./scripts/pre-apply-env.sh <project-id> prod
./scripts/open-tunnel.sh prod <project-id> <zone>
cd prod && terraform apply
cd .. && ./scripts/close-tunnels.sh

source ./scripts/pre-apply-mgmt.sh <project-id>
cd mgmt && terraform apply
```

## Cross-module handoffs (all via Secret Manager, no `terraform_remote_state`)

- `dev/`'s and `prod/`'s `nomad` module writes `octopus-deploy-token-{env}`
- `mgmt/`'s `octopus` module reads it back, as the `NomadToken` shared
  variable
- Everything Consul writes (Flag-4 agent/Nomad-integration tokens,
  Traefik's token) is consumed by Ansible/startup scripts only — no
  other `platform-config` module reads them

**`vault/` has zero cross-module dependency.** Its `ai_agent_config`
secret originally relayed `nomad-sentinel`'s Nomad ACL token from
`nomad/` — that field is dropped. `nomad-sentinel` is itself a Nomad
task; it should use its own Nomad Workload Identity to call Nomad's API
directly, same pattern as its Vault access, rather than a
Vault-relayed static token. Whether Nomad's own API actually supports
task-side WI auth the same confirmed way Vault/Consul do hasn't been
independently verified — `nomad/`'s module still mints a static
`nomad-sentinel-{env}` token as an interim fallback in case it doesn't;
this may become dead weight once that's confirmed.

## Things resolved this session, for the record

- **Octopus Vault AppRole — dropped entirely.** Traced through the
  actual data Octopus needs (`NomadToken`, `VaultAddr`, `ImageTag`,
  `Datacenter`, `RemediationMode`, `ResourceLimits`) and none of it was
  ever a Vault secret read — `NomadToken` comes from `nomad/` via
  Secret Manager directly, the rest are static or per-release values.
  The AppRole built earlier this session had no real consumer.
- **28 Consul sidecar identity tokens — dropped entirely.** Confirmed
  against Nomad's own docs: Nomad 1.7+ requests a scoped Consul Service
  Identity token automatically at allocation time via a job spec's
  `connect { sidecar_service {} }` block, using the `nomad-client`
  policy's `acl:write` grant (added to that policy this session). No
  static per-service token needs to be pre-created or distributed.
- **Provider aliasing removed entirely.** Since each of `dev/`/`prod/`
  is now a single-environment root, there's no reason for
  `consul.dev`/`consul.prod`-style aliases inside the modules —
  `var.environment` decides everything, and the provider block itself
  is a single, unaliased instance per root directory.

## Things still flagged — verify before applying

1. **`consul_acl_token.id` attribute** — not independently verified
   against the pinned provider version. Confirm before first apply.
2. **`octopus/`'s provider schema** (`modules/octopus/environments.tf`,
   `variables-shared.tf`) — lifecycle phase blocks and library-variable-
   set resource names are written from general shape knowledge, not
   freshly checked against current provider docs.
3. **`postgresql` as one destination for two databases** — assumes one
   Postgres Nomad job hosting both `metrics`/`monitoring` databases via
   separate `CREATE DATABASE`s, not two separate Postgres jobs. Not yet
   decided which shape `nomad-jobs/` will actually use.
4. **`nomad-sentinel-{env}` static token** — may be removable once
   Nomad WI-for-Nomad's-own-API is confirmed (see "Cross-module
   handoffs" above).
5. **Deployment targets** (`octopus/`) — no
   `octopusdeploy_deployment_target`-equivalent resource exists.
   Per the architecture doc, Nomad is reached via a Script Console/
   RunScript step calling the Nomad CLI/API directly — confirm this
   before deciding whether a target resource is needed at all.
6. **`vault-admin`'s DB credential — `rotate-root` considered, not implemented.**
   Vault's database secrets engine supports `rotate-root`: a one-time,
   manually-triggered call that has Vault silently replace its own
   Postgres credential with a value only Vault ever knows afterward —
   closing the gap where `random_password.vault_admin_db`'s value
   sitting in Terraform state could otherwise be used to bypass Vault
   entirely. Deliberately not wired in — it's an imperative action
   Terraform can't model as a resource (no before/after state to diff),
   and everything works correctly without it. Noted here as a real,
   considered hardening step for later, not an oversight.

## Service intentions call graph

Derived directly from `docker-compose.services.yaml`'s `depends_on`/env
address wiring — see `modules/consul/locals.tf`. L4-only
(`Sources[].Action`) throughout; the resource type supports full L7
matching (path/method/header/JWT-claim authorization) without
restructuring anything here if finer-grained rules are ever needed.
