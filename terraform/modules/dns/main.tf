# Cloud DNS — Private Zone
#
# Public zones (boutique.lefrancis.org, dev.boutique.lefrancis.org) are
# managed in Cloudflare.
# This creates the platform.lefrancis.org private zone only, resolvable
# inside the VPC. Record sets (grafana., vault., nomad., consul., octopus.)
# are deliberately NOT created here: their target is the internal Traefik
# VM IP. They are created during apply in compute/

resource "google_dns_managed_zone" "platform_private" {
  project     = var.project_id
  name         = "platform-lefrancis-org"
  dns_name    = var.dns_name
  description = "Private zone for internal platform tools (Vault, Nomad, Consul, Octopus, Grafana)"
  visibility  = "private"

  private_visibility_config {
    networks {
      network_url = var.network_self_link
    }
  }

  labels = var.labels
}