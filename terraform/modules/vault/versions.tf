terraform {
  required_providers {
    vault         = { 
      source = "hashicorp/vault", 
      version = "~> 5.0" 
    }
    google = {
      source  = "hashicorp/google"
      version = "~> 7.0"
    }
    random = { 
      source = "hashicorp/random", 
      version = "~> 3.0"
    }
    null = { 
      source = "hashicorp/null", 
      version = "~> 3.0"
    }
  }
}
