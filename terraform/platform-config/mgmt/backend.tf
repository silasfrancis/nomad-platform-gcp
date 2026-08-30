terraform {
  required_providers {
    vault         = { 
      source = "hashicorp/vault", 
      version = "5.11.0" 
    }
    octopusdeploy = {
      source  = "OctopusDeploy/octopusdeploy"
      version = "1.19.3"
    }
    google = {
      source  = "hashicorp/google"
      version = "7.43.0"
    }
    random = { 
      source = "hashicorp/random", 
      version = "3.9.0"
    }
  }

  backend "gcs" {}
}

provider "vault" {
  address      = "https://vault.platform.lefrancis.org:8443"
  token        = var.vault_token
}

provider "octopusdeploy" {
  address = "https://octopus.platform.lefrancis.org:8443"
  api_key = var.octopus_api_key
  space_id = var.octopus_space_id
}

provider "google" {
  project = var.project_id
  region  = var.region
}
