terraform {
  required_version = ">= 1.9.0"

  required_providers {
    octopusdeploy = {
      source  = "OctopusDeploy/octopusdeploy"
      version = "~> 0.40" # NOTE: verify current version — not independently confirmed this session
    }
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }

  backend "gcs" {
    bucket = "REPLACE-terraform-state-bucket"
    prefix = "platform-config/octopus"
  }
}

provider "octopusdeploy" {
  address = var.octopus_address
  api_key = var.octopus_api_key # TF_VAR_octopus_api_key, exported by scripts/pre-apply.sh
}

provider "google" {
  project = var.gcp_project
}
