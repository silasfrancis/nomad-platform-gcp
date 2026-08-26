terraform {
  required_providers {
    nomad  = { 
      source  = "hashicorp/nomad", 
      version = "~> 2.0" 
    }
    google = { 
      source = "hashicorp/google", 
      version = "~> 7.0" 
    }
  }
}
