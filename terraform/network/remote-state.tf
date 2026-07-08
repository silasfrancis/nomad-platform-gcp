data "terraform_remote_state" "bootstrap" {
  backend = "gcs"

  config = {
    bucket = var.platform_tfstate_bucket
    prefix = var.bootstrap_tfstate_key
  }
}