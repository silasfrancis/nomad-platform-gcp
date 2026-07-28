# platform-config

Four modules under `modules/` (`vault`, `octopus`, `consul`, `nomad`) —
the actual resource logic, parameterized by `var.environment` where it
matters. Three root directories call them: `mgmt/` (Vault + Octopus —
single instances, serving both environments internally), `dev/`, and
`prod/` (Consul + Nomad — two genuinely separate clusters, one
directory each). Each root directory is its own Terraform state and
its own `terraform apply`.

## Why three roots, not one combined apply

Consul and Nomad dev/prod are two independent, non-federated clusters
with different credentials and different CA-signed certificate chains.
Separate directories mean only one environment can ever be touched by
a given `apply` — there's no shared backend or shared code path where
a mistake could silently cross environments.

## Apply order

`dev/` and `prod/` have no dependency on `mgmt/` — apply either in any
order, independently, at any time.

`mgmt/` has one dependency: it reads `octopus-deploy-token-{dev,prod}`
from Secret Manager, written by `dev/`'s and `prod/`'s `nomad` module.
So `dev/` and `prod/` must each be applied at least once before
`mgmt/`'s first successful apply of the Octopus deployment variables.
After that, all three are independent on every subsequent apply.

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

## Cross-module handoffs

Every value one module needs from another goes through GCP Secret
Manager — never `terraform_remote_state`, since these are genuinely
separate states with no reason to read each other's raw resource
attributes.

- `dev/`'s and `prod/`'s `nomad` module writes `octopus-deploy-token-{env}`
- `mgmt/`'s `octopus` module reads it back, as the `NomadAclToken`
  library variable
- Everything Consul writes (agent/Nomad-integration tokens, Traefik's
  token) is consumed by Ansible/VM startup scripts only — no other
  `platform-config` module reads them

`vault/` has no cross-module dependency at all. `nomad-sentinel`
authenticates to both Vault and Nomad's own API using Workload
Identity — no static token is minted or relayed between modules for
it.

## Design notes

- **No Octopus/Vault integration.** Octopus reads every value it needs
  (Nomad API URL/token/CA cert, Slack webhook) directly from Secret
  Manager. Nothing routes through Vault.
- **Consul sidecar tokens are not statically managed.** Nomad 1.7+
  requests a scoped Consul Service Identity token automatically at
  allocation time via a job spec's `connect { sidecar_service {} }`
  block, using the `nomad-client` policy's `acl:write` grant. No static
  per-service token is pre-created or distributed.
- **Vault Workload Identity is the default authentication path for
  Nomad tasks.** Static ACL tokens are commented out in
  `modules/nomad/acl.tf` and should only be enabled for a workload that
  genuinely cannot use Workload Identity.
- **`vault-admin`'s database credential is a dedicated role**, separate
  from the Postgres container's own bootstrap superuser — created by
  that superuser during initialization, holding `CREATEROLE` plus
  ownership of both databases, never the superuser account itself.
  Vault's own `rotate-root` feature could later replace this
  credential with a value nobody (including the operator) can read
  back out, closing the gap where the Terraform-generated password
  sitting in state could otherwise be used to bypass Vault directly.
  Not implemented — noted here as a deliberate, considered next step.

## Things flagged for verification before applying

1. **`consul_acl_token.id`** — the attribute used throughout `consul/`
   to push token values to Secret Manager. Confirm this matches the
   pinned provider version's schema (vs. `SecretID`/`secret_id`).
2. **Octopus provider schema** — the lifecycle retention blocks,
   `octopusdeploy_process`/`process_step`/`process_steps_order`, and
   the Cloud Region deployment target resources are written from the
   current provider documentation but not independently exercised
   against a live Octopus instance. Verify field names before the
   first real apply.
3. **Postgres connection resolution** — Vault's database connections
   point at `127.0.0.1:8600`/`8601` (each environment's local Consul
   DNS resolver on the management host). Confirm the exact Postgres
   hostname registered by the Postgres Nomad job matches what's
   expected, and that the driver Vault's plugin uses resolves through
   the intended resolver.
4. **`postgresql` as one destination for two databases** assumes a
   single Postgres Nomad job hosting both the `metrics` and
   `monitoring` databases via separate `CREATE DATABASE` statements,
   rather than two separate Postgres jobs. Confirm before job specs are
   written.
5. **Job-scoped ACL policy binding for `nomad-sentinel`** — Workload
   Identity requires associating the policy with the specific job
   (via `-job`/`-group`/`-task` scoping) rather than a standalone
   token. The exact Terraform resource argument for this hasn't been
   confirmed against the provider's current schema.

## Service intentions call graph

Derived from the application's own service-to-service wiring — see
`modules/consul/locals.tf`. L4-only (`Sources[].Action`) throughout;
the resource type supports full L7 matching (path/method/header/JWT-
claim authorization) without restructuring anything here, if
finer-grained rules are ever needed.

## Deployment scripts

`.github/workflows/scripts/` holds the five scripts each project's
deployment process runs: validate, deploy, wait for healthy, smoke
test, notify Slack. These are packaged with each release artifact and
extracted by Octopus at deploy time — kept here for now as plain shell
scripts so they can move into a dedicated deployment package later
without changing how the deployment process calls them.
