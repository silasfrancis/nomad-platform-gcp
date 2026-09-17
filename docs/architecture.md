# Architecture

Platform architecture covering infrastructure, networking, compute, orchestration, autoscaling, secrets, ingress, monitoring, runtime security, and backup/restore.

## Infrastructure as code

Terraform is split into four layers: `bootstrap` → `network` → `compute` → `platform-config`. Each layer has its own GCS state backend and reads outputs from earlier layers with `terraform_remote_state`.

`platform-config` is split by concern and environment:

- **`mgmt/`** — Vault and Octopus. Both are project-wide singletons, so this applies once and manages both environments' resources internally (Vault's module takes `nomad_environments = ["dev", "prod"]` and creates a JWT backend per environment; Octopus's module takes the same list and creates environments/projects for both).
- **`dev/`** and **`prod/`** — each owns only that environment's own Consul and Nomad ACL setup. A Vault policy change never touches a Consul token, and a dev ACL change can never reach prod, because they're different Terraform states entirely.

Terraform also manages configuration for GCP, Vault, Consul, Nomad, and Octopus Deploy. Their policies, ACL tokens, namespaces, and Octopus projects are defined as code.

Ansible and Packer handle configuration and image creation. **Ansible** (10 roles) configures services and system state that are not part of the image, with execution ordered through `Taskfile.yaml`. **Packer** builds the `nomad-server` and `nomad-client` images used by `compute`.

## Network — VPC & subnets

One VPC contains five subnets: `subnet-mgmt`, plus private and public subnets for `dev` and `prod`. Dev and prod isolation is enforced with explicit firewall rules between the private subnets.

```
                                    Internet
                                        │
                              80/443 only, public IPs
                                        ▼
                     ┌───────────────────────────────────────┐
                     │  dev-public          prod-public        │
                     │  (Traefik, public — Let's Encrypt HTTP-01) │
                     └───────────────────┬─────────────────────┘
                                          │ dynamic ports (20000-32000),
                                          │ Consul catalog API (8501) only
                     ┌────────────────────┴──────────────────────┐
                     │  dev-private          prod-private          │
                     │  (Nomad + Consul servers & clients)          │
                     │       dev ──X── prod   (explicit deny,       │
                     │        both directions, no exceptions)       │
                     └────────────────────┬──────────────────────┘
                                          │ admin ports (4646, 8501) +
                                          │ mesh dynamic ports + Postgres,
                                          │ from subnet-mgmt only
                     ┌────────────────────┴──────────────────────┐
                     │                subnet-mgmt                  │
                     │  mgmt-vm:  Vault · Octopus · Grafana ·       │
                     │            GitHub Actions runner              │
                     │  traefik-internal: mgmt / dev-internal /     │
                     │            prod-internal listeners            │
                     │  — IAP tunnel only, no public IP anywhere —   │
                     └─────────────────────────────────────────────┘
```

| Subnet | CIDR | Purpose |
|---|---|---|
| `subnet-mgmt` | `10.2.1.0/24` | Vault, Octopus, Grafana, GitHub runner, internal Traefik — no public IPs |
| `subnet-dev-private` | `10.0.1.0/24` | dev Nomad/Consul servers & clients — no public IPs |
| `subnet-dev-public` | `10.0.2.0/24` | dev's public Traefik VM — external IP |
| `subnet-prod-private` | `10.1.1.0/24` | prod Nomad/Consul servers & clients — no public IPs |
| `subnet-prod-public` | `10.1.2.0/24` | prod's public Traefik VM — external IP |

Firewall rules are grouped by purpose:

| Purpose | Rules | What it allows |
|---|---|---|
| Admin access | `iap-ssh`, `iap-traefik-internal` | IAP range (`35.235.240.0/20`) only — SSH to every subnet, plus tunnels to `traefik-internal`'s 5 HTTPS entrypoints |
| GCP health checks | `health-check-nomad-clients` | Google's own probe ranges → Nomad client API (4646), for MIG health |
| Environment isolation | `deny-dev-to-prod`, `deny-prod-to-dev` | Explicit deny, both directions, between the two private subnets |
| Cluster protocols | `nomad-internal`, `consul-internal`, `consul-connect-sidecars` | Nomad RPC/Serf, Consul RPC/gossip/API, and Envoy sidecar traffic — within and across the two private subnets |
| Public ingress | `traefik-public` | `0.0.0.0/0` → the two public subnets, 80/443 only |
| Public Traefik → its own cluster | `traefik-backend-dev`, `traefik-backend-prod`, `consul-catalog-dev-public`, `consul-catalog-prod-public` | Each public Traefik reaches only its own environment's dynamic ports and Consul catalog API — never the other environment's |
| Internal Traefik → both clusters | `traefik-internal-nomad`, `traefik-internal-nomad-consul-servers` | `subnet-mgmt` → both private subnets, admin ports + mesh dynamic ports + Postgres — the cross-environment access path, described below |
| Internal Traefik ↔ mgmt-vm | `traefik-internal-mgmt`, `nomad-clients-to-traefik-internal` | Vault/Octopus/Grafana ports and Traefik's own entrypoints, both directions within `subnet-mgmt` |
| Metrics scraping | `prometheus-scrape`, `prometheus-to-traefik-internal`, `prometheus-to-traefik-public-dev`, `prometheus-to-traefik-public-prod` | Prometheus (running in each private subnet) reaching every scrape target across subnets |

## Compute

GCE, split by role rather than a single uniform node shape:

- **Nomad servers** — static VMs, one per environment (dev configurable 1–3, prod fixed at 3 for a Raft quorum), `e2-small`, one per zone so a single-zone outage doesn't take out every server at once. Static because Raft consensus needs stable membership; a MIG replacing an instance mid-term would fight leader election.
- **Nomad clients** — MIGs, split into **on-demand** and **spot** pools per environment (`e2-standard-2`), scaled by Nomad Autoscaler — see [Autoscaling](#autoscaling). Spot capacity absorbs the disposable, stateless boutique services; the on-demand pool is the floor that everything else runs on.
- **Management VM** (`mgmt-vm`) — one static `e2-standard-2` in `subnet-mgmt`, running Vault, Octopus Server, the GitHub Actions self-hosted runner, and Grafana. A control-plane singleton; it is not horizontally scaled.
- **`traefik-internal`** — its own separate static VM in `subnet-mgmt` (not the same VM as `mgmt-vm`), running the platform's internal ingress. See [Ingress](#ingress).
- **Public Traefik** — one small VM per environment (`traefik-dev`: `e2-micro`, `traefik-prod`: `e2-small`) in that environment's public subnet, with a external IP.

**Images are built with Packer** — one shared `nomad.pkr.hcl` template and two `.pkrvars.hcl` files (`nomad-server`, `nomad-client`), each pointing at the corresponding Ansible playbook. Server and client images share the base hardening and role set but run different services. Per-environment values (certificates, gossip keys, datacenter, and retry-join configuration) are supplied by the GCE startup script rather than baked into the image.

Data disks (`nomad-data`, `consul-data`, and `mgmt-vm`'s `vault-data`/`sql-data`/`docker-data`) are formatted and mounted by the GCE startup script. The script uses `blkid` and `mountpoint -q` checks so the operation is safe across reboots.

## Orchestration

- **Workload Identity** is used where supported. Nomad tasks that need Vault or Nomad-API access use `identity { env = true }` and JWT auth, not a token baked into the job spec. The exception is: `identity.env` only injects `NOMAD_TOKEN`, not `NOMAD_ADDR`/TLS material, so a task also talking to the Nomad API directly (`nomad-sentinel`) still needs explicit `NOMAD_ADDR`/`NOMAD_CACERT`/`NOMAD_TLS_SERVER_NAME` wired in.
- **Namespaces:** `boutique`, `datastore`, `monitoring`, `security`, `operations`, `plugins` Each namespace maps to Consul ACL scope and an Octopus project boundary. `plugins` (CSI, Autoscaler) is deployed straight via `nomad-jobs/plugins/deploy-plugins.sh` rather than through Octopus, since these are cluster-level infrastructure jobs with no separate release lifecycle.
- **Consul Connect uses deny-by-default intentions.** Intentions are generated from `locals.intentions` in Terraform. There's no explicit "deny all others" entry — ACL `default_policy = "deny"` already covers everything not listed, so adding one would be a redundant no-op.
- **Not all services are mesh members.** Postgres isn't — it keeps a static port (`5432`), reachable through Traefik's TCP passthrough entrypoint and firewall rules that reference that port literally. Access control for the database is credential-based (Vault dynamic Postgres roles + Postgres-side `GRANT`s), not network-mesh-based. Bringing Postgres into Connect would mean widening firewall rules to the whole dynamic-port range without a corresponding requirement.
- **Vault and Consul are separate.** They're independent systems here: Consul provides mesh and service discovery for Nomad allocations; Vault authenticates Nomad tasks directly over Workload Identity/JWT. Nothing routes secrets through the mesh.
- **Cluster membership uses GCE Cloud Auto-Join**, keyed off environment-specific network tags (`nomad-server-dev`/`-prod`, `consul-server-dev`/`-prod`) — no static join list to keep in sync as instances are replaced.

## Autoscaling

Nomad Autoscaler is used for both node-count and task-count scaling.

### Cluster scaling

Nomad Autoscaler manages the client MIGs rather than the GCE autoscaler. GCE's own scale-in stabilization field (`scale_in_control`) is left commented out on every pool that has a matching Nomad Autoscaler policy, with a note to only re-enable it for a pool that doesn't have one. Two reasons this split matters:

1. **GCE's native autoscaler has no idea what Nomad has scheduled.** It scales on the VM's own CPU utilization and will happily terminate an instance that's hosting live allocations, with no coordination. Nomad Autoscaler's `gce-mig` target sets `node_drain_deadline = "10m"` and `node_purge = true` — before an instance leaves the MIG, Nomad drains it first, rescheduling its allocations elsewhere.
2. **It scales on Nomad's allocated resources, not raw host metrics.** The policy queries Prometheus for `nomad_client_allocated_*` vs `nomad_client_unallocated_*` — the fraction of CPU/memory allocated by Nomad — rather than host-level utilization, which can be misleading if workloads are memory-bound while CPU sits idle, or vice versa.

Each environment has two policies: `cluster_policy_ondemand` and `cluster_policy_spot` — each with its own min/max (dev: 1–5 per pool; prod: 1–10), each targeting 70% CPU/memory. Both checks in each policy share a `group` label, so either metric alone can trigger scale-in — this fixes a bug where two *ungrouped* checks allowed either metric to veto a scale-in requested by the other (see `docs/CHANGELOG.md`).

### Workload scaling

Nomad's `scaling {}` stanza is used for task-count scaling and is evaluated by the Autoscaler agent. It is currently applied to `frontend` — 1–5 instances, 70% CPU target, 30-second evaluation — the `frontend` service in the reference workload. The same configuration can be applied to other jobs; it is currently used by the reference workload.

## Secret management

- KV v2 (`kv/`) for static config, the database secrets engine (`database/`) for dynamic Postgres roles.
- **One JWT auth backend per environment** (`jwt-nomad-dev`, `jwt-nomad-prod`), each pointed at that environment's own Nomad JWKS endpoint — a dev workload identity can't authenticate against prod, and vice versa, by construction.
- **One Vault policy per (consumer, environment) pair** — `metrics-api-dev`, `nomad-sentinel-prod`, etc. — rather than one broad policy per service.
- **Dynamic-only Postgres credentials** for `metrics-api` and `nomad-sentinel` (`database/creds/metrics-api-{env}`, `database/creds/monitoring-{env}`) — short-lived roles minted per-lease, not a shared static password.
- **GitHub OIDC into Vault**, not the other way around: a `jwt-github-actions` backend with `bound_claims` pinned to the specific repo (and currently `refs/heads/main`), granting read on `kv/data/cicd/*`. The self-hosted runner living on the same box as Vault means CI never needs a long-lived Vault token to exist at all.

Full PKI/mTLS design (the CA chain, leaf rotation, gossip keys) and the Consul/Nomad ACL token model live in [`docs/security.md`](security.md) — they are documented in [`docs/security.md`](security.md).

## Ingress

Ingress is split into public and internal paths.

### Public

`traefik-dev` and `traefik-prod` run in the public subnet of each environment and use external IPs. They issue Let's Encrypt certificates through **HTTP-01**. Routing uses **Consul Catalog only** with `exposedByDefault: false`. A service must have the `traefik.enable=true` Consul tag to be exposed. The current public service is `frontend`.

### Internal

`traefik-internal` is a VM in `subnet-mgmt` with no public IP. Administrative access uses an IAP tunnel. It doesn't run one Traefik process; it runs three, each its own systemd unit and config file, sharing the same Ansible role:

```
                    subnet-mgmt (IAP tunnel only)
   ┌──────────────────────────────────────────────────────┐
   │                                                        │
   │   traefik-internal (one VM, three Traefik processes)   │
   │                                                        │
   │   ┌─────────┐   ┌──────────────┐   ┌───────────────┐   │
   │   │  mgmt   │   │ dev-internal │   │ prod-internal  │   │
   │   │ :8443   │   │ :8444/:8446  │   │  :8445/:8447   │   │
   │   └───┬─────┘   └──────┬───────┘   └────────┬──────┘   │
   │       │  static        │ static +           │ static + │
   │       │  routes only   │ Consul catalog      │ catalog  │
   │       ▼                ▼ (dev token)         ▼ (prod)   │
   │   mgmt-vm         nomad-dev-server-*   nomad-prod-server-* │
   │  (Vault/Octopus/       + dev mesh          + prod mesh   │
   │   Grafana)          internal services     internal svcs │
   └──────────────────────────────────────────────────────┘
```

- **`mgmt`** — static file-provider routes only, no Consul Catalog (`mgmt` never joins Consul): `vault.platform.<domain>` → Vault (8200), `octopus.platform.<domain>` → Octopus (8080), `grafana.platform.<domain>` → Grafana (3000).
- **`dev-internal`** / **`prod-internal`** — two providers side by side, per environment:
  1. **Static routes** for that environment's own admin surfaces: `nomad-dev.platform.<domain>`/`nomad-prod...` → that environment's Nomad servers (4646), `consul-dev...`/`consul-prod...` → Consul's HTTPS API (8501).
  2. **A Consul Catalog provider**, scoped to that environment's own catalog token, for anything registered in the mesh that's internal-only — `nomad-sentinel`, `metrics-api`, `falco-webhook`, `prometheus`, `loki`. These are tagged onto a **second, distinct HTTPS entrypoint** (named `internal`, port 8446/8447) rather than the instance's normal `websecure` entrypoint — to keep internal-only services separate from the public entrypoint.
  3. Each also owns a **TCP passthrough entrypoint** (`15432`/`15433`) straight to Postgres — not an HTTP route, since it isn't HTTP traffic.

### DNS

One private Cloud DNS zone, `platform.<domain>`, resolvable only inside the VPC. Every internal hostname — Vault, Octopus, Grafana, both environments' Nomad/Consul, both Postgres aliases, `nomad-sentinel`, `metrics-api`, `falco-webhook`, `prometheus`, `loki` — resolves to the exact same address: `traefik-internal`'s internal IP. Traefik selects the route from the request `Host()` header. Public hostnames (`boutique.<domain>`, `dev.boutique.<domain>`) live in Cloudflare instead, entirely separate from this zone.

### Dev/prod access

`traefik-internal-nomad` and `traefik-internal-nomad-consul-servers` allow `subnet-mgmt` to reach both private environments. These are the only firewall rules that permit this cross-environment access.

### Certificates

Internal instances use **Cloudflare DNS-01**. Public instances use **HTTP-01**.

## Monitoring

- **Metrics**: Prometheus, service discovery via the Consul catalog — no static scrape targets to maintain as clients scale in/out. Scrapes Nomad servers/clients, Consul agents, Vault, Node Exporter, Traefik, Online Boutique, `metrics-api`, and Grafana Alloy itself.
- **Logs**: Loki, shipped by Grafana Alloy, labeled by `job`/`task`/`namespace`/`node_id`/`alloc_id`/`env` — with labels that identify the allocation and workload.
- **Dashboards**: Grafana, provisioned entirely from JSON baked into its image at build time  — dashboards and datasource configuration are baked into the image, so Grafana does not use a persistent disk. Currently ships one dashboard (node health); the rest of the originally-planned set (Nomad cluster, Online Boutique, Vault, Traefik, `nomad-sentinel`, Falco, `metrics-api`) uses the same provisioning pipeline but isn't built out yet.
- **`nomad-sentinel`**: an AI-assisted monitoring service that polls Nomad allocation state, filters out superseded/stopped allocations, and uses Gemini (`gemini-2.5-flash`, `thinking_budget=0`) to summarizes allocation state in Slack and can propose remediations. Talks to Postgres via its own dynamic Vault credential, and to the Nomad API directly (with explicit TLS wiring, since Workload Identity alone doesn't provide that).

## Runtime security

Falco runs on every Nomad client, monitoring kernel syscalls on Nomad clients. Trivy handles image scanning during CI; see [`docs/security.md`](security.md). Five custom rules supplement Falco's default set:

| Rule | Detects | Priority |
|---|---|---|
| Unexpected privilege escalation | `setuid`/`setgid`/`capset`/`ptrace` inside a container | CRITICAL |
| Shell spawned in container | An interactive shell process appearing post-start — a common post-exploitation signal | WARNING |
| Unexpected outbound connection | A container process opening a connection on a port outside the platform's known service ports | WARNING |
| Sensitive file read | Reads of `/etc/shadow`, SSH keys, or anything with `vault-token` in the path, from inside a container | CRITICAL |
| Suspected crypto mining | High-CPU process paired with an outbound connection to a known mining-pool port | CRITICAL |

Falco alerts are sent to `monitoring/falco-webhook`, which:

1. Ships every alert to Loki, tagged `source=falco`, regardless of severity — full audit trail, nothing dropped.
2. For anything `WARNING` or above, calls `nomad-sentinel` directly over internal HTTP — sends security alerts to the same `nomad-sentinel` triage service.

## Backup & restore

Four stateful systems are backed up daily to the `platform-artifacts` GCS bucket, which uses CMEK and 90-day retention. Each component has its own restore script.

| Component | Schedule | Mechanism | Destination |
|---|---|---|---|
| Vault | Daily 02:00 UTC | Raft snapshot, mgmt-vm systemd timer | `gs://.../platform-artifacts/vault-snapshots/` |
| Consul | Daily 02:30 UTC | `consul snapshot save`, periodic Nomad batch job (spot node) | `gs://.../platform-artifacts/consul-snapshots/{env}/` |
| Postgres | Daily 03:00 UTC | `pg_dump` per database, periodic Nomad batch job (spot node) | `gs://.../platform-artifacts/pg-backups/{env}/` |
| Octopus (SQL Server) | Daily 03:00 UTC | T-SQL `BACKUP DATABASE`, mgmt-vm systemd timer | `gs://.../platform-artifacts/sql-backups/` |

Restore procedures differ by component:

- **Vault** — Vault runs as a single node with GCP KMS auto-unseal. `restore-vault.sh` handles two cases: **same node / data corruption** (Vault's already up and unsealed — call the restore API directly with the live token) vs. **fresh node / full loss** (a brand-new Raft store has no keyring yet, so the script runs a throwaway `vault operator init` purely to get one authenticated call in, then discards it the instant the snapshot's own keyring takes over — verification then switches to the original root token stored in Secret Manager.
- **Consul** — restores live, against a running agent, using a management-level ACL token pulled from Vault (not Secret Manager — Consul comes up after Vault in the dependency chain, so it can rely on Vault being available). dev and prod are two entirely separate single-server datacenters; restoring one never touches the other's catalog, ACLs, or intentions.
- **Postgres** — connects as the Vault-managed `vault-root` superuser, not a dynamic per-connection credential, since a scoped app role won't have privileges to drop/recreate schema during a restore. The two databases (`metrics`, `monitoring`) are restored independently — a bad restore of one is never allowed to touch the other.
- **Octopus** — Octopus runs on SQL Server, so its restore procedure is different: stop the Octopus service (it holds open connections that block `RESTORE DATABASE`), run `sqlcmd`'s `RESTORE DATABASE ... WITH REPLACE` inside the SQL Server container, restart, then hit Octopus's own health API to confirm it can see its data again.
- **Nomad** — restoring from a Raft snapshot rather than just replaying job specs from git matters for one specific reason: it preserves the Workload Identity signing keyring. Redeploying jobs from git after a server loss would mint a *new* keyring, silently orphaning every `jwt-nomad-*` auth mount in Vault until each one is manually repointed at the new JWKS endpoint. Restoring from snapshot brings the same keyring back and Vault auth just keeps working.

Restore scripts that access private endpoints such as the Nomad API or Postgres print the required IAP tunnel command.

## Known limitations

Current limitations:

- **Postgres and Redis aren't pinned to a dedicated node pool.** They're scheduled like anything else and can land on a node alongside unrelated workloads. At larger scale or with stricter isolation requirements, this would need a dedicated node pool/class if traffic or blast-radius requirements grew.
- **No TLS on the Postgres connection itself** — `sslmode=disable` over a dedicated, non-TLS TCP entrypoint.
- **No entrypoint-level TLS backstop.** Traefik's `websecure` entrypoint doesn't force `tls {}` as a fallback — it's reachable HTTP-only if a router were ever misconfigured without a TLS block.
- **No per-consumer Redis ACL users** — Redis auth is a single shared password, not per-consumer key isolation.
- **No disaster-recovery runbook for a destroyed persistent disk.** The `restore-*.sh` scripts restore *data* onto an already-healthy, already-mounted disk. Recovering from a lost PD — detach/replace, remount, then run the matching restore script — isn't automated.
- **No Nomad-native admission control.** Nomad OSS has no equivalent to Kyverno-style mandatory image-signature verification at the scheduler level. The practical mitigation is a `cosign verify` step inside the Octopus deployment scripts, which only covers jobs going through that pipeline.
- **Database credentials require an allocation restart to rotate.** Vault-rendered credential files update on disk when a lease renews, but the application doesn't currently watch that file and reconnect — a rotation means restarting the allocation, not a live pool swap.
- **Canary promotion is health-based, not traffic-split.** Octopus auto-promotes a canary once its allocations report healthy; Traefik doesn't yet weight live traffic between the canary and stable allocations during that window.

## Planned improvements

Planned changes:

- **Postgres dedicated-node scheduling** — pin Postgres to a specific/reserved node via Nomad client config and/or a dedicated node pool/class. Effort is not yet scoped.
- **Dynamic DB credential reloading** — update `metrics-api` and `nomad-sentinel` to watch the Vault-rendered credential file and reload their connection pool on change, removing the restart-on-rotation limitation above.
- **Traefik canary traffic splitting** — weighted traffic between canary and stable allocations via `traefik.consulcatalog.canary`-style tags during a canary deployment, in addition to Octopus's health-based auto-promotion.

## Application layer

Google's Online Boutique (11 services), vendored with its own service-mesh and Nomad job-spec layer wrapped around it — plus `metrics-api`, a small Go service backing the platform's own metrics history. A known issue is: `currencyservice`'s gRPC server needed explicit HTTP/2 keepalive channel options to avoid a cross-implementation ping-flood disconnect through the Envoy sidecar — see [`docs/CHANGELOG.md`](CHANGELOG.md).
