terraform {
  required_version = ">= 1.9.0"

  required_providers {
    consul = { source = "hashicorp/consul", version = "~> 2.0" }
    nomad  = { source = "hashicorp/nomad", version = "~> 2.0" }
    google = { source = "hashicorp/google", version = "~> 6.0" }
  }

  backend "gcs" {
    bucket = "REPLACE-terraform-state-bucket"
    prefix = "platform-config/dev"
  }
}

# Single, unaliased providers — this directory always targets dev.
# Environment selection happens by choice of directory, not by a
# runtime variable, so there is no risk of applying against the wrong
# cluster from here.
#
# Both addresses go through traefik-internal's dev-internal instance,
# reached via scripts/open-tunnel.sh dev — Consul and Nomad share the
# one tunneled port (8444) and are told apart by Host header, matching
# the two static routes that instance's Ansible role renders. No
# ca_file/cacert anywhere here: traefik-internal terminates TLS with a
# real Let's Encrypt certificate (Cloudflare DNS-01), so the system
# trust store is all either provider needs — see scripts/pre-apply-env.sh.
provider "consul" {
  address = "https://consul-dev.platform.lefrancis.org:8444"
  token   = var.consul_token
}

provider "nomad" {
  address   = "https://nomad-dev.platform.lefrancis.org:8444"
  secret_id = var.nomad_token
}

provider "google" {
  project = var.gcp_project
}
