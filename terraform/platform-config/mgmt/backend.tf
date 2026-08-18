terraform {
  required_providers {
    vault         = { 
      source = "hashicorp/vault", 
      version = "5.11.0" 
    }
    octopusdeploy = { 
      source = "OctopusDeploy/octopusdeploy", 
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
  address      = var.vault_address
  token        = var.vault_token
  ca_cert_file = pathexpand("~/.terraform-certs/management-ca.pem")
}

provider "octopusdeploy" {
  address = var.octopus_address
  api_key = var.octopus_api_key
}

provider "google" {
  project = var.project_id
  region  = var.region
}
