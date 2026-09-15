terraform {
  required_version = ">= 1.9.0"

  required_providers {
    consul = {
      source  = "hashicorp/consul"
      version = "2.23.0"
    }
    nomad = {
      source  = "hashicorp/nomad"
      version = "2.6.1"
    }
    vault = {
      source  = "hashicorp/vault"
      version = "5.11.0"
    }
    google = {
      source  = "hashicorp/google"
      version = "7.43.0"
    }
  }

  backend "gcs" {}
}


# Both addresses go through traefik-internal's prod-internal instance,
# reached via scripts/open-tunnel.sh prod — Consul and Nomad share the
# one tunneled port (8445) and are told apart by Host header, matching
# the two static routes that instance's Ansible role renders
# (see ansible/roles/traefik/defaults/main.yaml for config references).

provider "consul" {
  address = "https://consul-prod.platform.lefrancis.org:8445"
  token   = var.consul_token
}

provider "nomad" {
  address   = "https://nomad-prod.platform.lefrancis.org:8445"
  secret_id = var.nomad_token
}

provider "vault" {
  address      = "https://vault.platform.lefrancis.org:8443"
  token        = var.vault_token
}

provider "google" {
  project = var.project_id
  region  = var.region
}
