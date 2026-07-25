terraform {
  required_version = ">= 1.9.0"

  required_providers {
    nomad = {
      source  = "hashicorp/nomad"
      version = "~> 2.0"
    }
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }

  backend "gcs" {
    bucket = "REPLACE-terraform-state-bucket"
    prefix = "platform-config/nomad"
  }
}

# Same aliasing rationale as consul/providers.tf — two independent
# clusters, reached via separate persistent IAP tunnels
# (localhost:14646/14647).
provider "nomad" {
  alias   = "dev"
  address = "http://localhost:14646"
  secret_id = var.nomad_token_dev
  ca_file   = var.nomad_cacert_dev
}

provider "nomad" {
  alias     = "prod"
  address   = "http://localhost:14647"
  secret_id = var.nomad_token_prod
  ca_file   = var.nomad_cacert_prod
}

provider "google" {
  project = var.gcp_project
}
