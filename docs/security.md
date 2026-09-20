# Security

Security controls for identity and access, network isolation, PKI, secrets, Consul/Nomad ACLs, and the software supply chain.

## Identity and access

- VMs are accessed through IAP using SSH or TCP tunnels and OS Login. Static SSH keys are not used.
- Service account key creation is disabled by organization policy (`iam.disableServiceAccountKeyCreation`). The two Nomad Autoscaler service accounts have a resource-tag-based exception because they require GCE API access that is not available through the metadata server.
- Human access uses separate Vault, Consul, and Nomad operator roles rather than a shared root credential for routine administration.

## Network

One VPC with isolation enforced by firewall rules. The grouped rule set (19 rules) is documented in [`docs/architecture.md`](architecture.md#network--vpc--subnets); the security-relevant summary:

- No VM has a public IP except the two public Traefik instances. Administrative access uses IAP; `35.235.240.0/20` is the administrative source range.
- Dev and prod are separated by explicit deny rules in both directions: `deny-dev-to-prod` and `deny-prod-to-dev`.
- `traefik-internal` can reach both environments through two narrowly scoped firewall rules for admin ports, mesh dynamic ports, and Postgres. See [`docs/architecture.md`](architecture.md#the-one-deliberate-crossing-of-the-devprod-boundary).
- Vault, Nomad API/UI, Octopus, Grafana, and Postgres are private-network services and are reachable through the internal Traefik instance.

## PKI & mTLS

Internal Nomad and Consul cluster traffic uses TLS with a self-signed trust chain. A cloud-managed CA is not used for internal traffic.

```
   ca-dev (RSA-4096, 10y)        ca-prod (RSA-4096, 10y)      management-ca (RSA-4096, 10y)
        │                              │                              │
        ├── consul-server-cert-dev     ├── consul-server-cert-prod    └── vault-cert
        ├── consul-client-cert-dev     ├── consul-client-cert-prod
        ├── nomad-server-cert-dev      ├── nomad-server-cert-prod
        └── nomad-client-cert-dev      └── nomad-client-cert-prod
            (825-day leaves, zone-wildcard SANs)
```

- Three RSA-4096 CAs with 10-year validity: `dev`, `prod`, and `management`. Dev and prod use separate CAs.
- Leaf certificates have 825-day validity and are issued separately for Nomad and Consul server/client roles by the environment CA.
- Vault uses a leaf certificate signed by the `management` CA.
- Consul and Nomad gossip encryption keys are generated separately for each environment.
- Certificates use zone-wildcard SANs to accommodate GCE internal DNS names when instances are replaced.
- `scripts/generate-and-push-pki.sh` generates the PKI material and stores it in Secret Manager. Rotation currently reruns the complete script; individual leaf rotation is not supported.

## Secrets management

Two systems are used:

- **Vault** - runtime secrets for workloads, including dynamic Postgres credentials and KV configuration, plus CI secrets accessed through GitHub OIDC.
- **GCP Secret Manager** - secrets required by Terraform, Ansible, and VM startup, including PKI material, ACL bootstrap tokens, and Octopus credentials. Access is divided by consumer:

| Tier | Readable by | Example |
|---|---|---|
| `root` | Human operator only | CA private keys, Vault recovery keys |
| `operator` | Human operator only, for `platform-config` runs | Vault/Consul/Nomad operator tokens |
| `mgmt` | `management-vm-sa` only | Octopus admin credentials, Vault TLS key |
| `scoped` | Explicit per-secret IAM binding | PKI leaf material, per-env agent/ACL tokens - each carries its own precise grant instead of inheriting a tier-wide one |

Secret Manager, the state/artifact GCS buckets, and Artifact Registry use CMEK (customer-managed KMS keys).

## Consul / Nomad ACL model

Four Consul token types are used per environment:

```
Consul agent token ──────────► self-registration, anti-entropy only
                                (same shape, server or client agent)

Nomad server's Consul token ──► agent:read, node:write, service:write,
                                 acl:write, mesh:write
                                 (Nomad manages Connect config entries)

Nomad client's Consul token ──► agent:read, node:write, service:write
                                 (no acl/mesh write - clients don't
                                  manage Connect config)

Consul DNS token ─────────────► DNS interface only, nothing else
```

1. **Consul agent token** - narrow, node-identity scope (self-registration, anti-entropy). Same shape for server and client agents.
2. **Nomad server's own Consul token** - Nomad-as-a-Consul-client, for service registration, auto-join discovery, and Connect config-entry management (`agent`/`node`/`service` write, `acl`/`mesh` write).
3. **Nomad client's own Consul token** - same purpose, narrower policy (no `acl`/`mesh` write - clients don't manage Connect config).
4. **Consul's DNS token**, separate again - used only for the DNS interface, not agent operations.

Eight ACL secrets are used in total (four types per environment). Tokens are applied through the node configuration at boot (`acl.tokens.agent`, `consul.token`) rather than through a post-start CLI command.

ACL bootstrap runs through Ansible playbooks (`consul-acl-bootstrap.yaml`, `nomad-acl-bootstrap.yaml`) against the running servers. The playbooks check Secret Manager for existing bootstrap data and wait for leader election before bootstrapping.

## Supply chain

- Container images are scanned with Trivy before push. A failing scan blocks the pipeline and the report is archived.
- Images are signed with Cosign and receive an SBOM attestation. Both the signature and attestation are verified in CI.
- CI authenticates to Vault with GitHub OIDC for CI secrets, scoped to the repository and branch.
- Build and Push to Artifact Registry with immutable tags.
- CI creates octopus package and pushes release
- Octopus deploys to Nomad via Nomad API

See [`ci-cd.md`](ci-cd.md) for more information on the supply chain.