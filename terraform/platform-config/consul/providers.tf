terraform {
  required_version = ">= 1.9.0"

  required_providers {
    consul = {
      source  = "hashicorp/consul"
      version = "~> 2.0"
    }
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }

  backend "gcs" {
    bucket = "REPLACE-terraform-state-bucket"
    prefix = "platform-config/consul"
  }
}

# Two Aliased Providers — dc-dev / dc-prod Are Independent, Non-Federated
# Datacenters, Each Reached Via Its Own Persistent IAP Tunnel
# (scripts/open-tunnels.sh — localhost:18500/18501). Tokens/CA paths
# come in as TF_VAR_* (not CONSUL_HTTP_TOKEN/CONSUL_CACERT env vars),
# since a single shared env var can't hold two different per-alias
# values the way it can for the single, unaliased Vault provider.
provider "consul" {
  alias   = "dev"
  address = "localhost:18500"
  token   = var.consul_token_dev
  ca_file = var.consul_cacert_dev
}

provider "consul" {
  alias   = "prod"
  address = "localhost:18501"
  token   = var.consul_token_prod
  ca_file = var.consul_cacert_prod
}

provider "google" {
  project = var.gcp_project
}
