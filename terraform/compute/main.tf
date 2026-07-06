locals {
  bootstrap = data.terraform_remote_state.bootstrap.outputs
  network   = data.terraform_remote_state.network.outputs

  # SA emails needed as raw strings (service_account block wants the bare
  # email, not the "serviceAccount:..." member format bootstrap outputs).
  management_vm_sa_email = trimprefix(local.bootstrap.management_vm_sa_member, "serviceAccount:")
  nomad_client_sa_email   = trimprefix(local.bootstrap.nomad_client_sa_member, "serviceAccount:")
  nomad_server_sa_email   = trimprefix(local.bootstrap.nomad_server_sa_member, "serviceAccount:")
  traefik_sa_email        = trimprefix(local.bootstrap.traefik_sa_member, "serviceAccount:")

  zones = ["${var.region}-a", "${var.region}-b", "${var.region}-c"]

  # Shared, Unconditional — Not Gated By active_environments
  #
  # mgmt-vm serves both dev and prod (Vault, Octopus, Grafana, internal
  # Traefik) — it's created every apply regardless of which environments
  # are active, same reasoning as bootstrap/network being non-workspaced.

  shared_instances = {
    "mgmt-vm" = {
      machine_type            = "e2-standard-2"
      zone                     = local.zones[0]
      subnetwork               = local.network.subnets["subnet-mgmt"].self_link
      external_ip              = false
      service_account_email    = local.management_vm_sa_email
      boot_disk_size_gb        = 50
      tags                     = ["mgmt"]
      labels                   = { role = "mgmt" }
      # startup_script wired in once the Ansible bootstrap/cloud-init
      # sequence for Vault/Octopus/Grafana/internal-Traefik is written.
    }
  }

  # Environment-Scoped — Gated By active_environments
  #
  # nomad-dev-server count is configurable 1-3 (architecture doc 1.3);
  # nomad-prod-server is fixed at 3 for a real Raft quorum. Each instance
  # gets its own zone off local.zones so a single-zone outage doesn't take
  # out every server at once.

  dev_server_instances = {
    for i in range(var.nomad_dev_server_count) : "nomad-dev-server-${i}" => {
      machine_type            = "e2-small"
      zone                     = local.zones[i % length(local.zones)]
      subnetwork               = local.network.subnets["subnet-dev-private"].self_link
      external_ip              = false
      service_account_email    = local.nomad_server_sa_email
      boot_disk_size_gb        = 20
      tags                     = ["nomad-server", "consul-server"]
      labels                   = { role = "nomad-server", environment = "dev" }
    }
  }

  prod_server_instances = {
    for i in range(3) : "nomad-prod-server-${i}" => {
      machine_type            = "e2-small"
      zone                     = local.zones[i % length(local.zones)]
      subnetwork               = local.network.subnets["subnet-prod-private"].self_link
      external_ip              = false
      service_account_email    = local.nomad_server_sa_email
      boot_disk_size_gb        = 20
      tags                     = ["nomad-server", "consul-server"]
      labels                   = { role = "nomad-server", environment = "prod" }
    }
  }

  traefik_instances = {
    "traefik-dev" = {
      machine_type            = "e2-micro"
      zone                     = local.zones[0]
      subnetwork               = local.network.subnets["subnet-dev-public"].self_link
      external_ip              = true
      service_account_email    = local.traefik_sa_email
      boot_disk_size_gb        = 20
      tags                     = ["traefik"]
      labels                   = { role = "traefik", environment = "dev" }
    }
    "traefik-prod" = {
      machine_type            = "e2-small"
      zone                     = local.zones[0]
      subnetwork               = local.network.subnets["subnet-prod-public"].self_link
      external_ip              = true
      service_account_email    = local.traefik_sa_email
      boot_disk_size_gb        = 20
      tags                     = ["traefik"]
      labels                   = { role = "traefik", environment = "prod" }
    }
  }

  env_instances = merge(
    local.dev_server_instances,
    local.prod_server_instances,
    local.traefik_instances,
  )

  active_env_instances = {
    for name, cfg in local.env_instances : name => cfg
    if contains(var.active_environments, cfg.labels.environment)
  }

  # Final map fed to the static-vm module. shared_instances is
  # unconditional — active_environments = [] still creates mgmt-vm and
  # nothing else.
  instances = merge(local.shared_instances, local.active_env_instances)

  # Nomad Client MIGs — same env-gating as the static VMs above. All four
  # are env-scoped; there's no "shared" MIG the way mgmt-vm is a shared VM.
  all_migs = {
    "nomad-dev-ondemand" = {
      machine_type            = "e2-standard-2"
      subnetwork               = local.network.subnets["subnet-dev-private"].self_link
      min_replicas             = 1
      max_replicas             = 5
      spot                     = false
      service_account_email    = local.nomad_client_sa_email
      labels                   = { role = "nomad-client", environment = "dev", pool = "ondemand" }
      environment              = "dev"
    }
    "nomad-dev-spot" = {
      machine_type            = "e2-standard-2"
      subnetwork               = local.network.subnets["subnet-dev-private"].self_link
      min_replicas             = 0
      max_replicas             = 5
      spot                     = true
      service_account_email    = local.nomad_client_sa_email
      labels                   = { role = "nomad-client", environment = "dev", pool = "spot" }
      environment              = "dev"
    }
    "nomad-prod-ondemand" = {
      machine_type            = "e2-standard-4"
      subnetwork               = local.network.subnets["subnet-prod-private"].self_link
      min_replicas             = 2
      max_replicas             = 10
      spot                     = false
      service_account_email    = local.nomad_client_sa_email
      labels                   = { role = "nomad-client", environment = "prod", pool = "ondemand" }
      environment              = "prod"
    }
    "nomad-prod-spot" = {
      machine_type            = "e2-standard-4"
      subnetwork               = local.network.subnets["subnet-prod-private"].self_link
      min_replicas             = 1
      max_replicas             = 10
      spot                     = true
      service_account_email    = local.nomad_client_sa_email
      labels                   = { role = "nomad-client", environment = "prod", pool = "spot" }
      environment              = "prod"
    }
  }

  active_migs = {
    for name, cfg in local.all_migs : name => cfg
    if contains(var.active_environments, cfg.environment)
  }
}

# Static VMs

module "static_vm" {
  source        = "../modules/static-vm"
  project_id    = var.project_id
  disk_cmek_key = local.bootstrap.disk_cmek_key_id
  instances     = local.instances
}

# Nomad Client MIGs

module "nomad_client_mig" {
  source        = "../modules/nomad-client-mig"
  project_id    = var.project_id
  region        = var.region
  disk_cmek_key = local.bootstrap.disk_cmek_key_id
  zones         = local.zones
  migs          = local.active_migs
}

# DNS Recordsets — Deferred From network/
#
# The private zone (platform.lefrancis.org) was created in network/, but
# recordsets couldn't be added there since mgmt-vm's internal IP didn't
# exist yet. It does now. mgmt-vm is unconditional, so this always resolves.

resource "google_dns_record_set" "platform_wildcard" {
  project      = var.project_id
  name         = "*.platform.lefrancis.org."
  type         = "A"
  ttl          = 300
  managed_zone = local.network.dns_zone_name
  rrdatas      = [module.static_vm.instances["mgmt-vm"].internal_ip]
}
