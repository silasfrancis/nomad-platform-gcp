# Packer — nomad-client-mig Golden Image

Only one image is baked via Packer in this project — `nomad-server` and
`mgmt-vm` stay on bare Debian, fully configured by a direct Ansible run
(see `ansible/playbooks/mgmt.yml` / `nomad-servers.yml`). Only the
Nomad client MIG needs a pre-baked image, since new instances appear
unattended during autoscale/Spot replacement with no laptop in the loop.

## Prerequisites

1. `terraform/bootstrap` must already be applied — it's what creates
   `packer-builder-sa` itself (and grants it `compute.instanceAdmin.v1`,
   `compute.storageAdmin`, `iam.serviceAccountUser`,
   `iap.tunnelResourceAccessor`, `compute.networkViewer`), plus every
   Secret Manager secret *container* the next step writes into. Nothing
   below this line exists until bootstrap has run.
2. `terraform/network` must also already be applied — the build VM's
   `subnetwork` field points at `subnet-mgmt`, which doesn't exist until
   this layer is applied. Note `terraform/compute` itself is NOT required
   before a Packer build — the build only needs bootstrap (SA + secrets)
   and network (the subnet); `compute/` is where the resulting image
   later gets *consumed* (the MIG's `source_image`), not a prerequisite
   for producing it.
3. `scripts/generate-and-push-pki.sh` must have been run at least once —
   the bake fetches `consul-ca-cert`, `nomad-ca-cert`, `nomad-client-cert`,
   `nomad-client-key`, and `vault-cert` directly from Secret Manager
   (running as `packer-builder-sa`), so all of these must already exist
   as secret *versions* (the script only adds versions into containers
   bootstrap already created — see step 1).
4. `packer-builder-sa` needs `secretAccessor` on those five secrets
   specifically (via each secret's own `iam` block in
   `terraform/bootstrap`'s `secrets` map, not a broad tier grant).
5. Install required plugins once: `packer init nomad-client.pkr.hcl`
6. Copy `nomad-client.pkrvars.hcl.example` to `nomad-client.pkrvars.hcl`
   (gitignored) and fill in real values.

## Build

```bash
cd packer/nomad-client
packer build -var-file="nomad-client.pkrvars.hcl" nomad-client.pkr.hcl
```

This runs the `common`, `consul`, `nomad`, `docker`, `falco` roles against
the ephemeral build VM (via `ansible/playbooks/nomad-clients.yml`,
overridden to target `all` since Packer's own generated inventory doesn't
contain the `role_nomad_client` group the playbook normally targets).

Per-instance/per-environment values (datacenter, retry_join, node meta,
Consul's client cert/key/gossip key) are **not** part of this bake — the
GCP startup script (`compute/startup-scripts/nomad-client-startup.sh`)
supplies those at real boot, since this same image serves both dev and
prod.

## After A Successful Build

The resulting image is named `nomad-client-image-<timestamp>` and tagged
with `image_family = "nomad-client"`. Point `compute/main.tf`'s
`nomad-client-mig` instance template's `source_image` at either the
specific pinned name (reproducible, requires a deliberate bump per
rebuild — recommended default) or `projects/<project>/global/images/family/nomad-client`
(always-latest, no Terraform change needed per rebuild, less
reproducible/auditable).
