terraform {
  required_version = ">= 1.9.0"

  required_providers {
    consul = { source = "hashicorp/consul", version = "~> 2.0" }
    nomad  = { source = "hashicorp/nomad", version = "~> 2.0" }
    google = { source = "hashicorp/google", version = "~> 6.0" }
  }

  backend "gcs" {
    bucket = "REPLACE-terraform-state-bucket"
    prefix = "platform-config/prod"
  }
}

# Single, unaliased providers — this directory always targets prod.
# Environment selection happens by choice of directory, not by a
# runtime variable, so there is no risk of applying against the wrong
# cluster from here.
#
# Both addresses go through traefik-internal's prod-internal instance,
# reached via scripts/open-tunnel.sh prod — Consul and Nomad share the
# one tunneled port (8445) and are told apart by Host header, matching
# the two static routes that instance's Ansible role renders. Whichever
# of prod's (up to 3) Nomad/Consul server nodes is reachable is enough:
# the static route's loadBalancer lists every one of them. No
# ca_file/cacert anywhere here — see dev/providers.tf's comment, same
# reasoning applies.
provider "consul" {
  address = "https://consul-prod.platform.lefrancis.org:8445"
  token   = var.consul_token
}

provider "nomad" {
  address   = "https://nomad-prod.platform.lefrancis.org:8445"
  secret_id = var.nomad_token
}

provider "google" {
  project = var.gcp_project
}
