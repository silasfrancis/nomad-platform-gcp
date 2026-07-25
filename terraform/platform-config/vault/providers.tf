terraform {
  required_version = ">= 1.9.0"

  required_providers {
    vault = {
      source  = "hashicorp/vault"
      version = "~> 4.0"
    }
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  backend "gcs" {
    bucket = "REPLACE-terraform-state-bucket"
    prefix = "platform-config/vault"
  }
}

# Vault — Token And CA Cert Read From Environment
# VAULT_TOKEN and VAULT_CACERT are exported by scripts/pre-apply.sh
# before this folder is ever applied. Neither is referenced as a
# Terraform variable here, so neither lands in this folder's state or
# plan output.
provider "vault" {
  address = var.vault_address
}

provider "google" {
  project = var.gcp_project
}
