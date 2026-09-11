locals {
  # Nomad CPU is expressed in MHz.
  cpu_default = 200

  cpu_overrides = {
    frontend        = 300
    cartservice     = 300
    checkoutservice = 300
    adservice       = 300

    postgres   = 300
    prometheus = 300
    loki       = 300

    alloy           = 100
    node-exporter   = 50
    falco-webhook   = 100
    consul-snapshot = 100
  }

  memory_default = 256

  memory_overrides = {
    frontend    = 384
    cartservice = 384
    adservice   = 512

    postgres   = 512
    prometheus = 512
    loki       = 512

    paymentservice        = 300
    currencyservice       = 300
    emailservice          = 300
    recommendationservice = 300
    loadgenerator         = 300

    shippingservice = 128
    alloy           = 128
    node-exporter   = 64
    falco-webhook   = 128
    consul-snapshot = 128
  }

  cpu_service_regex    = join("|", keys(local.cpu_overrides))
  memory_service_regex = join("|", keys(local.memory_overrides))

  # Every project except datastore gets a ReplicaCount.
  replica_projects = {
    for k, v in local.projects : k => v
    if k != "datastore"
  }

  replica_defaults = {
    dev  = 1
    prod = 2
  }
}

locals {
  environments = toset(["dev"])

  env_by_key = {
    dev  = octopusdeploy_environment.dev.id
    prod = octopusdeploy_environment.prod.id
  }
  nomad_address_by_env = {
    dev  = var.nomad_address_dev
    prod = var.nomad_address_prod
  }

  traefik_public_ip_by_env = {
    dev  = var.traefik_public_ip_dev
    prod = var.traefik_public_ip_prod
  }

  traefik_public_port_by_env = {
    dev  = var.traefik_public_port_dev
    prod = var.traefik_public_port_prod
  }

  traefik_internal_ip_by_env = {
    dev  = var.traefik_internal_ip_dev
    prod = var.traefik_internal_ip_prod
  }

  traefik_internal_port_by_env = {
    dev  = var.traefik_internal_port_dev
    prod = var.traefik_internal_port_prod
  }

  # Base image path — same registry regardless of environment, unlike
  # everything else that's split dev/prod. One repo, images promoted
  # through environments by tag, not rebuilt
  artifact_registry_path = var.artifact_registry_path
  platform_gcs_bucket = var.platform_gcs_bucket
}

