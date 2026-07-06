data "terraform_remote_state" "bootstrap" {
  backend = "gcs"
  config = {
    bucket = "nomad-platform-gcp-tfstate"
    prefix = "bootstrap"
  }
}

data "terraform_remote_state" "network" {
  backend = "gcs"
  config = {
    bucket = "nomad-platform-gcp-tfstate"
    prefix = "network"
  }
}
