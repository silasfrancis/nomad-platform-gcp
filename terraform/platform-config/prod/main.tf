module "consul" {
  source      = "../modules/consul"
  environment = "prod"
  gcp_project = var.gcp_project
}

module "nomad" {
  source      = "../modules/nomad"
  environment = "prod"
  gcp_project = var.gcp_project
}
