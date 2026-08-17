terraform {
  required_version = ">= 1.9.0"

  required_providers {
    vault         = { 
      source = "hashicorp/vault", 
      version = "~> 4.0" 
    }
    octopusdeploy = { 
      source = "OctopusDeploy/octopusdeploy", 
      version = "~> 0.40" 
    }
    google = {
      source  = "hashicorp/google"
      version = "7.43.0"
    }
    random = { 
      source = "hashicorp/random", 
      version = "~> 3.6" 
    }
  }

  backend "gcs" {}
}

provider "vault" {
  address = var.vault_address
# token
}

provider "octopusdeploy" {
  address = var.octopus_address
  api_key = var.octopus_api_key
}

provider "google" {
  project = var.project_id
  region  = var.region
}
