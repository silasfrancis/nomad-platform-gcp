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
provider "consul" {
  address = "localhost:18501"
  token   = var.consul_token
  ca_file = var.consul_cacert
}

provider "nomad" {
  address   = "http://localhost:14647"
  secret_id = var.nomad_token
  ca_file   = var.nomad_cacert
}

provider "google" {
  project = var.gcp_project
}
