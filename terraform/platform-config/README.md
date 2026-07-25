# platform-config

Four independent Terraform root modules (separate state files, separate
`backend "gcs"` prefixes) — `vault/`, `consul/`, `nomad/`, `octopus/` —
plus a `scripts/` folder that exports every token/CA-cert path each
module needs before it's applied. This is deliberately **not** one big
combined root module: keeping them separate means each system's
blast radius is isolated, matching the same philosophy as the four
independent Terraform layers in `bootstrap/`/`network/`/`compute/`.

## Apply order

1. `vault/` — engines, JWT/AppRole/OIDC auth backends, policies, static
   KV secrets
2. `consul/` — ACL tokens/policies, sidecar identity tokens, service
   intentions
3. `nomad/` — namespaces, ACL policies/tokens (writes two secrets
   `vault/` needs — see "Cross-module handoffs" below, so **must** run
   before re-applying `vault/` if `vault/`'s `ai_agent_config` secret is
   being created for the first time)
4. `octopus/` — environments, lifecycle, projects, shared variable set
   (reads a secret written by `nomad/`, so must run after it)

## Before first apply

```
source ./scripts/pre-apply.sh <gcp-project-id>
./scripts/open-tunnels.sh <gcp-project-id> <zone>   # only needed before consul/ or nomad/
cd consul && terraform apply
cd ../nomad && terraform apply
./scripts/close-tunnels.sh
```

`vault/` and `octopus/` don't need the tunnels — Vault's already
reachable at its real DNS name, and Octopus's provider talks to
`octopus.platform.lefrancis.org` directly.

## Cross-module handoffs (why there's no `terraform_remote_state` anywhere)

Since each folder is a fully separate state file, none of them can
reference another's resource attributes directly. Every handoff goes
through GCP Secret Manager instead — consistent with how `platform-config`
itself receives its own bootstrap tokens from Ansible:

- `nomad/` writes `nomad-sentinel-token-{env}` and
  `octopus-deploy-token-{env}`
- `vault/` reads `nomad-sentinel-token-{env}` back in, to populate
  `kv/data/{env}/ai-agent/config`'s `nomad_token` field
- `octopus/` reads `octopus-deploy-token-{env}` back in, as the
  `NomadToken` shared library variable
- `consul/` writes 8 agent/Nomad-integration tokens + 28 sidecar
  identity tokens + 2 Traefik tokens, all consumed by Ansible/the
  startup scripts, not by another `platform-config` folder

## Things flagged during this build — resolve/verify before applying

1. **`consul_acl_token.id` attribute** (used throughout `consul/` to
   push token secret values to Secret Manager) — not independently
   verified against the pinned provider version's actual schema this
   session. Confirm it's the right attribute (vs. `SecretID`/`secret_id`)
   before first apply.
2. **`octopus/`'s provider schema** — `octopusdeploy_lifecycle`'s phase
   block arguments and the library-variable-set resource names are
   written from general shape knowledge, not freshly checked against
   current provider docs. This folder needs the most scrutiny before
   applying of the four.
3. **28 Consul sidecar identity tokens, statically minted** — flagged in
   `consul/acl-sidecar-tokens.tf` as a known simplification. Nomad 1.7+'s
   Consul Workload Identity would remove the need for static tokens here
   entirely, mirroring the Vault JWT pattern already used. Worth
   revisiting once `nomad-jobs/` is actually being written.
4. **`history.py`'s docstring** now contradicts `vault/engines.tf` —
   the code comment says the monitoring database intentionally avoids
   Vault's dynamic engine; this build gives it dynamic creds anyway
   (matching metrics-api). Update the docstring, or reopen this decision
   if the static-credential design was actually preferred.
5. **`postgresql` as one destination for two databases** (`metrics-api`
   and `ai-agent` both intending into `postgresql` in
   `consul/locals.tf`) assumes one Postgres Nomad job hosting both
   `metrics`/`monitoring` databases, not two separate Postgres jobs.
   Matches Part 2's open question from the handover doc — not yet
   decided which shape `nomad-jobs/` will actually use.
6. **`traefik-dev`/`traefik-prod`** as intention source names in an
   earlier draft this session were removed — Traefik isn't a Connect
   mesh member (catalog provider only), so it can't be named as an
   intention `Sources[].Name` at all. `frontend` has no intention entry
   in `consul/intentions.tf` as a result. Confirm this reasoning holds
   once Traefik's actual job spec exists.
7. **Deployment targets** (`octopus/`) — no
   `octopusdeploy_deployment_target`-equivalent resource was written.
   Per the architecture doc, Nomad is reached via a Script Console/
   RunScript step calling the Nomad CLI/API directly, not a first-class
   Octopus target object — confirm this is still the intended mechanism
   before deciding whether a target resource is needed at all.

## Service intentions call graph

Derived directly from `docker-compose.services.yaml`'s `depends_on`/env
address wiring — see `consul/locals.tf` for the full mapping and
reasoning per pair. Uses L4-only intentions (`Sources[].Action`)
throughout; no `Permissions`/HTTP path matching is used yet. The
resource type supports full L7 matching (path/method/header, even
per-JWT-claim authorization) without restructuring anything here —
see Consul's `service-intentions` config entry reference for the
complete schema if finer-grained rules are ever needed (e.g. restricting
which caller can hit `metrics-api`'s `/db-check` vs `/metrics`).
