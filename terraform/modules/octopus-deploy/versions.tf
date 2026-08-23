terraform {
  required_providers {
    octopusdeploy = {
      source  = "OctopusDeploy/octopusdeploy"
      version = "~> 1.0"
    }
    google = {
      source  = "hashicorp/google"
      version = "~> 7.0"
    }
  }
}