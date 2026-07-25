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

# Single, unaliased providers — this directory IS dev, full stop.
# No environment ambiguity possible: you can only be standing here,
# talking to dev's tunnel, applying dev's state.
provider "consul" {
  address = "localhost:18500"
  token   = var.consul_token
  ca_file = var.consul_cacert
}

provider "nomad" {
  address   = "http://localhost:14646"
  secret_id = var.nomad_token
  ca_file   = var.nomad_cacert
}

provider "google" {
  project = var.gcp_project
}
