terraform {
  required_providers {
    vault  = { source = "hashicorp/vault", version = "~> 4.0" }
    google = { source = "hashicorp/google", version = "~> 6.0" }
    random = { source = "hashicorp/random", version = "~> 3.6" }
  }
}
