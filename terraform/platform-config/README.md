# platform-config

Vault engines/policies, Consul/Nomad ACL tokens, and Octopus projects/environments for the platform, as three separate root modules: `mgmt/` (Vault + Octopus, single instances serving both environments), `dev/`, and `prod/` (Consul + Nomad, two genuinely independent clusters). Split into three because dev/prod are non-federated with different credentials and CA chains — separate states mean one `apply` can never touch the wrong environment.

## Apply

`dev/` and `prod/` don't depend on each other or on `mgmt/` — apply either, any order, for whichever environments actually exist (set upstream by `terraform/compute`'s `active_environments`; `mgmt/`'s `nomad_provisioned`/`nomad_environments` need to match).

`mgmt/`'s `octopus` module normally needs `dev`/`prod` applied at least once first, since it reads `octopus-deploy-token-{dev,prod}` from Secret Manager once they exist. To bring `mgmt/` up before either does, set `use_dummy_secrets = true` on the `octopus` module and fix the tokens later, from the Octopus UI or on `mgmt/`'s next apply.

Providers reach Vault/Octopus/Consul/Nomad through an IAP tunnel, so first time on a machine:

```bash
./scripts/update-hosts.sh   # one-time, follow its instructions
```

Then per root module — `pre-apply-env.sh`/`pre-apply-mgmt.sh` fetch that module's operator tokens (Consul/Nomad/Vault, or Vault/Octopus for `mgmt`) from Secret Manager and export them as `TF_VAR_*` so the provider blocks can authenticate:

```bash
source ./scripts/pre-apply-env.sh <project-id> dev
./scripts/open-tunnel.sh dev <project-id> <zone>
cd dev && terraform apply
cd .. && ./scripts/close-tunnels.sh
```

Repeat for `prod`, then `mgmt` via `source ./scripts/pre-apply-mgmt.sh <project-id>`.

## Cross-module handoffs

Every value one module needs from another goes through Secret Manager, never `terraform_remote_state` — these are genuinely separate states with no reason to read each other's resource attributes.

## Deployment scripts

`.github/workflows/scripts/` holds the five scripts each deploy runs (validate, deploy, wait-healthy, smoke test, notify Slack) — packaged with the release artifact and extracted by Octopus at deploy time.