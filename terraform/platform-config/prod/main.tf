module "consul" {
  source      = "../../modules/consul"
  environment = "prod"
  gcp_project_id = var.project_id
}

module "nomad" {
  source      = "../../modules/nomad"
  environment = "prod"
  gcp_project_id = var.project_id
}

