module "consul" {
  source      = "../../modules/consul"
  environment = "dev"
  gcp_project_id = var.project_id
}

module "nomad" {
  source      = "../../modules/nomad"
  environment = "dev"
  gcp_project_id = var.project_id
}


