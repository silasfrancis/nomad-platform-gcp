terraform {
  required_version = ">= 1.9.0"

  required_providers {
    vault         = { source = "hashicorp/vault", version = "~> 4.0" }
    octopusdeploy = { source = "OctopusDeploy/octopusdeploy", version = "~> 0.40" }
    google        = { source = "hashicorp/google", version = "~> 6.0" }
  }

  backend "gcs" {
    bucket = "REPLACE-terraform-state-bucket"
    prefix = "platform-config/mgmt"
  }
}

# Single instances, both serving dev+prod internally — no aliasing
# needed. VAULT_TOKEN/VAULT_CACERT come from the environment
# (scripts/pre-apply-mgmt.sh); Octopus's api_key comes in as
# TF_VAR_octopus_api_key, same script.
provider "vault" {
  address = var.vault_address
}

provider "octopusdeploy" {
  address = var.octopus_address
  api_key = var.octopus_api_key
}

provider "google" {
  project = var.gcp_project
}
