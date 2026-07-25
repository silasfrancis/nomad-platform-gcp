module "consul" {
  source      = "../modules/consul"
  environment = "dev"
  gcp_project = var.gcp_project
}

module "nomad" {
  source      = "../modules/nomad"
  environment = "dev"
  gcp_project = var.gcp_project
}
