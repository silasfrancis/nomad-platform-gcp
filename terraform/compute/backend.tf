terraform {
  backend "gcs" {
    bucket = "nomad-platform-gcp-tfstate"
    prefix = "compute"
  }
}
