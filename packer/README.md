# Packer — Nomad Golden Images

This directory contains the Packer configuration used to build the golden images for the Nomad platform.

The same Packer template is used to build different image types by supplying the appropriate `.pkrvars.hcl` file. Currently, this is used for:

* `nomad-client` — used by the Nomad client MIGs.
* `nomad-server` — used by Nomad server instances.

The images contain the OS and platform configuration that should be present before an instance joins the environment. Configuration that is specific to an individual environment or instance is applied at startup by the relevant GCP startup script.

## Prerequisites

1. `terraform/bootstrap` must already be applied — it creates `packer-builder-sa` and grants it the permissions required to build Compute Engine images, including `compute.instanceAdmin.v1`, `compute.storageAdmin`, `iam.serviceAccountUser`, `iap.tunnelResourceAccessor`, and `compute.networkViewer`. It also creates the Secret Manager secret containers required by the build. Nothing below this line exists until bootstrap has run.

2. `terraform/network` must also be applied — the Packer build VM uses `subnet-mgmt`, which is created by this layer. `terraform/compute` is **not** required before a Packer build. The compute layer consumes the resulting images; it is not a prerequisite for producing them.

3. `gcloud` SDK must be installed on the machine running `packer build` — required by Packer when `use_iap = true`. This is separate from any Ansible-side `gcloud` usage.

4. Install the required Packer plugins once:

```bash
packer init .
```

5. Copy the appropriate variables example and fill in the required values:

```bash
cp nomad-client.pkrvars.hcl.example nomad-client.pkrvars.hcl
```
or:

```bash
cp nomad-server.pkrvars.hcl.example nomad-server.pkrvars.hcl
```

The actual `.pkrvars.hcl` files are gitignored.

## Build

The same Packer template is used for both image types. The variables file determines which image is produced and which Ansible playbook is applied.

### Nomad Client

```bash
packer build -var-file="nomad-client.pkrvars.hcl" .
```

This runs the roles required for the Nomad client image through `ansible/playbooks/nomad-clients.yaml`.

The Nomad client image contains:

* Base OS configuration
* Common system configuration
* Consul
* Nomad
* Docker
* Falco
* Other client-specific platform dependencies

### Nomad Server

```bash
packer build -var-file="nomad-server.pkrvars.hcl" .
```

This runs the roles required for the Nomad server image through `ansible/playbooks/nomad-servers.yaml`.

The Nomad server image contains:

* Base OS configuration
* Common system configuration
* Consul
* Nomad

## Image Configuration

The shared Packer template contains the common build configuration, while the variables file determines the image-specific values and Ansible playbook.

The two image types therefore share the same build infrastructure without duplicating the Packer configuration.

Per-instance and per-environment values are **not** baked into the images. These include:

* Datacenter
* `retry_join`
* Node metadata
* Consul client certificates and keys
* Consul gossip keys
* Environment-specific configuration
* Instance identity

These values are supplied by the appropriate GCP startup script when the instance boots. This allows the same golden image to be reused across environments such as dev and prod.

## After a Successful Build

The resulting image name and family are determined by the variables supplied to Packer.

For example, a Nomad client build produces an image similar to:

```text
nomad-client-image-<timestamp>
```

with:

```text
image_family = "nomad-client"
```

A Nomad server build similarly produces:

```text
nomad-server-image-<timestamp>
```

with:

```text
image_family = "nomad-server"
```

The resulting images can then be consumed by Terraform using either a **specific image name** or an **image family**.

A specific image is pinned and reproducible:

```text
projects/<project>/global/images/<image-name>
```

This is the recommended approach when you want a deliberate image-version change to result in a Terraform change.

An image family always resolves to the latest image in that family:

```text
projects/<project>/global/images/family/nomad-client
```

or:

```text
projects/<project>/global/images/family/nomad-server
```

This avoids changing Terraform for every image rebuild, but is less explicit and auditable because the resolved image can change when a new image is published.
