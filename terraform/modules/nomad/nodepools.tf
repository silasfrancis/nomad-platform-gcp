resource "nomad_node_pool" "on_demand" {
  name        = "on-demand"
  description = "GCE on-demand instances"
}

resource "nomad_node_pool" "spot" {
  name        = "spot"
  description = "GCE spot/preemptible instances"
}