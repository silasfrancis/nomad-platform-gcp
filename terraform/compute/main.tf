data "google_compute_zones" "available" {
  region = var.region
  status = "UP"
}

locals {
  bootstrap = data.terraform_remote_state.bootstrap.outputs
  network   = data.terraform_remote_state.network.outputs

  # Service account members
  management_vm_sa_member = local.bootstrap.service_accounts["management-vm-sa"].member
  nomad_client_sa_member_prod  = local.bootstrap.service_accounts["nomad-client-sa-prod"].member
  nomad_client_sa_member_dev  = local.bootstrap.service_accounts["nomad-client-sa-dev"].member
  nomad_server_sa_member_prod  = local.bootstrap.service_accounts["nomad-server-sa-prod"].member
  nomad_server_sa_member_dev  = local.bootstrap.service_accounts["nomad-server-sa-dev"].member
  traefik_vm_sa_member_prod       = local.bootstrap.service_accounts["traefik-vm-sa-prod"].member
  traefik_vm_sa_member_dev       = local.bootstrap.service_accounts["traefik-vm-sa-dev"].member
  traefik_vm_sa_member_internal = local.bootstrap.service_accounts["traefik-vm-sa-internal"].member


  zones = slice(data.google_compute_zones.available.names, 0, 3)
  #Instance scripts for Nomad Servers and Client MIGs
  instance_scripts_dir = "${path.module}/instance-scripts"
  nomad_server_startup_script = file("${local.instance_scripts_dir}/nomad-server-startup.sh")
  nomad_client_startup_script = file("${local.instance_scripts_dir}/nomad-client-startup.sh")
  nomad_client_spot_shutdown_script  = file("${local.instance_scripts_dir}/nomad-client-spot-shutdown.sh")


  # Shared, Unconditional — Not Gated By active_environments
  #
  # mgmt-vm (Vault, Octopus, Grafana, Github actions runner)
  # and traefik-internal (Traefik Internal)
  # — it's created every apply regardless of which environments
  # are active

  shared_instances = {
    "mgmt-vm" = {
      machine_type            = "e2-standard-2"
      zone                     = local.zones[0]
      subnetwork               = local.network.subnets["subnet-mgmt"].self_link
      external_ip              = false
      service_account_email    = local.management_vm_sa_member
      boot_disk_size_gb        = 50
      tags                     = ["mgmt"]
      labels                   = { role = "mgmt" }

      # Separate persistent disks for Vault's storage backend and SQL
      # Server's data files — kept off the boot disk so either can be
      # resized/snapshotted independently and survives a boot disk rebuild.
      # Sizes are placeholders; adjust once real data volume is known.
      additional_disks = [
        { name = "vault-data", size_gb = 20 },
        { name = "sql-data",   size_gb = 30 },
        { name = "mgmt-vm-docker-data",   size_gb = 50 },
      ]
    }
    "traefik-internal" = {
      machine_type            = "e2-small"
      zone                     = local.zones[0]
      subnetwork               = local.network.subnets["subnet-mgmt"].self_link
      static_external_ip       = false
      external_ip              = false
      service_account_email    = local.traefik_vm_sa_member_internal
      boot_disk_size_gb        = 20
      tags                     = ["traefik"]
      labels                   = { role = "traefik" }
    }
  }

  # Environment-Scoped — Gated By active_environments
  #
  # nomad-dev-server count is configurable 1-3 for a dev Raft quorum
  # nomad-prod-server is fixed at 3 for a real Raft quorum. Each instance
  # gets its own zone off local.zones so a single-zone outage doesn't take
  # out every server at once.

# Dev-Scoped Instances (Nomad Servers + Traefik Dev)
  dev_server_instances = merge(
    {
      for i in range(var.nomad_dev_server_count) : "nomad-dev-server-${i}" => {
        machine_type          = "e2-small"
        environment           = "dev"
        zone                  = local.zones[i % length(local.zones)]
        subnetwork            = local.network.subnets["subnet-dev-private"].self_link
        external_ip           = false
        service_account_email = local.nomad_server_sa_member_dev
        boot_disk_size_gb     = 20
        tags                  = ["nomad-server-dev", "consul-server-dev"]
        labels                = { role = "control-plane", environment = "dev" }
        startup_script        = local.nomad_server_startup_script
        additional_disks = [
          { name = "nomad-data", size_gb = 20 },
          { name = "consul-data",  size_gb = 20 },
        ]
      }
    },
    {
      "traefik-dev" = {
        machine_type          = "e2-micro"
        environment           = "dev"
        zone                  = local.zones[0]
        subnetwork            = local.network.subnets["subnet-dev-public"].self_link
        static_external_ip    = true
        external_ip           = true
        service_account_email = local.traefik_vm_sa_member_dev
        boot_disk_size_gb     = 20
        tags                  = ["traefik"]
        labels                = { role = "traefik", environment = "dev" }
      }
    }
  )

  # Prod-Scoped Instances (Nomad Servers + Traefik Prod)
  prod_server_instances = merge(
    {
      for i in range(3) : "nomad-prod-server-${i}" => {
        machine_type          = "e2-small"
        environment           = "prod"
        zone                  = local.zones[i % length(local.zones)]
        subnetwork            = local.network.subnets["subnet-prod-private"].self_link
        external_ip           = false
        service_account_email = local.nomad_server_sa_member_prod
        boot_disk_size_gb     = 20
        tags                  = ["nomad-server-prod", "consul-server-prod"]
        labels                = { role = "control-plane", environment = "prod" }
        startup_script        = local.nomad_server_startup_script
        additional_disks = [
          { name = "nomad-data", size_gb = 20 },
          { name = "consul-data",  size_gb = 20 },
        ]
      }
    },
    {
      "traefik-prod" = {
        machine_type          = "e2-small"
        environment           = "prod"
        zone                  = local.zones[0]
        subnetwork            = local.network.subnets["subnet-prod-public"].self_link
        static_external_ip    = true
        external_ip           = true
        service_account_email = local.traefik_vm_sa_member_prod
        boot_disk_size_gb     = 20
        tags                  = ["traefik"]
        labels                = { role = "traefik", environment = "prod" }
      }
    }
  )

  env_instances = merge(
    local.dev_server_instances,
    local.prod_server_instances,
  )

  active_env_instances = {
    for name, cfg in local.env_instances : name => cfg
    if contains(var.active_environments, cfg.environment)
  }

  # Final map fed to the instances module. shared_instances is
  # unconditional — active_environments = [] still creates mgmt-vm, traefik-internal and nothing else.
  instances = merge(local.shared_instances, local.active_env_instances)

  all_migs = {
    "nomad-dev-ondemand" = {
      machine_type            = "e2-standard-2"
      subnetwork               = local.network.subnets["subnet-dev-private"].self_link
      min_replicas             = 1
      max_replicas             = 5
      spot                     = false
      service_account_email    = local.nomad_client_sa_member_dev
      tags                     = ["nomad-client-dev", "consul-client-dev"]
      labels                   = { role = "worker", environment = "dev", pool = "on-demand" }
      environment              = "dev"
      scale_in_control         = { max_scaled_in_replicas_fixed = 1, time_window_sec = 300 }
      startup_script           = local.nomad_client_startup_script
    }
    "nomad-dev-spot" = {
      machine_type            = "e2-standard-2"
      subnetwork               = local.network.subnets["subnet-dev-private"].self_link
      min_replicas             = 0
      max_replicas             = 5
      spot                     = true
      service_account_email    = local.nomad_client_sa_member_dev
      tags                     = ["nomad-client-dev", "consul-client-dev"]
      labels                   = { role = "worker", environment = "dev", pool = "spot" }
      environment              = "dev"
      startup_script           = local.nomad_client_startup_script
      shutdown_script          = local.nomad_client_spot_shutdown_script
    }
    "nomad-prod-ondemand" = {
      machine_type            = "e2-standard-2"
      subnetwork               = local.network.subnets["subnet-prod-private"].self_link
      min_replicas             = 2
      max_replicas             = 10
      spot                     = false
      service_account_email    = local.nomad_client_sa_member_prod
      tags                     = ["nomad-client-prod", "consul-client-prod"]
      labels                   = { role = "worker", environment = "prod", pool = "on-demand" }
      environment              = "prod"
      scale_in_control         = { max_scaled_in_replicas_fixed = 1, time_window_sec = 300 }
      startup_script           = local.nomad_client_startup_script
    }
    "nomad-prod-spot" = {
      machine_type            = "e2-standard-2"
      subnetwork               = local.network.subnets["subnet-prod-private"].self_link
      min_replicas             = 1
      max_replicas             = 10
      spot                     = true
      service_account_email    = local.nomad_client_sa_member_prod
      tags                     = ["nomad-client-prod", "consul-client-prod"]
      labels                   = { role = "worker", environment = "prod", pool = "spot" }
      environment              = "prod"
      startup_script           = local.nomad_client_startup_script
      shutdown_script          = local.nomad_client_spot_shutdown_script
    }
  }

  active_migs = {
    for name, cfg in local.all_migs : name => cfg
    if contains(var.active_environments, cfg.environment)
  }
}

# Operator Access — IAP SSH + OS Login
#
# Project-wide grant to a single human identity

resource "google_project_iam_member" "operator_iap_tunnel" {
  project = var.project_id
  role    = "roles/iap.tunnelResourceAccessor"
  member  = "user:${var.platform_admin_email}"
}

resource "google_project_iam_member" "operator_os_login" {
  project = var.project_id
  role    = "roles/compute.osAdminLogin"
  member  = "user:${var.platform_admin_email}"
}

# Static VMs

module "instances" {
  source        = "../modules/instances"
  project_id    = var.project_id
  disk_cmek_key = local.bootstrap.disk_cmek_key_id
  instances     = local.instances
}

# MIGs

module "mig" {
  source        = "../modules/mig"
  project_id    = var.project_id
  region        = var.region
  disk_cmek_key = local.bootstrap.disk_cmek_key_id
  zones         = local.zones
  migs          = local.active_migs
}


locals {
  records = {
    vault       = module.instances.instances["traefik-internal"].internal_ip
    octopus     = module.instances.instances["traefik-internal"].internal_ip
    grafana     = module.instances.instances["traefik-internal"].internal_ip
    nomad-dev   = module.instances.instances["traefik-internal"].internal_ip
    consul-dev  = module.instances.instances["traefik-internal"].internal_ip
    nomad-prod  = module.instances.instances["traefik-internal"].internal_ip
    consul-prod = module.instances.instances["traefik-internal"].internal_ip
    postgres-dev = module.instances.instances["traefik-internal"].internal_ip
    postgres-prod = module.instances.instances["traefik-internal"].internal_ip
    nomad-sentinel-prod = module.instances.instances["traefik-internal"].internal_ip
    nomad-sentinel-dev = module.instances.instances["traefik-internal"].internal_ip
    metrics-api-dev = module.instances.instances["traefik-internal"].internal_ip
    metrics-api-prod = module.instances.instances["traefik-internal"].internal_ip
    falco-webhook-dev = module.instances.instances["traefik-internal"].internal_ip
    falco-webhook-prod = module.instances.instances["traefik-internal"].internal_ip
    prometheus-dev = module.instances.instances["traefik-internal"].internal_ip
    prometheus-prod = module.instances.instances["traefik-internal"].internal_ip
    loki-dev = module.instances.instances["traefik-internal"].internal_ip
    lokie-prod = module.instances.instances["traefik-internal"].internal_ip
  }
}

resource "google_dns_record_set" "this" {
  for_each     = locals.records
  name         = "${each.key}.${local.network.internal_dns_suffix}"
  managed_zone = local.network.internal_dns_zone_name
  type         = "A"
  ttl          = 300
  rrdatas      = [each.value]
}