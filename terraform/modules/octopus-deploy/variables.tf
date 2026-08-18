variable "gcp_project_id" {
  type = string
}

variable "nomad_address_dev" {
  type        = string
  description = "dev Nomad server address, used for the NomadApiUrl deployment variable"
}

variable "nomad_address_prod" {
  type        = string
  description = "prod Nomad server address, used for the NomadApiUrl deployment variable"
}

variable "slack_webhook_secret_name" {
  type        = string
  default     = "octopus-slack-webhook-url"
  description = "Name of the GCP Secret Manager secret holding the Slack webhook URL used by the Notify Slack deployment step. The secret itself is created and populated outside this module."
}

variable "traefik_public_ip_dev" {
  type = string
}

variable "traefik_public_port_dev" {
  type = string
}

variable "traefik_internal_ip_dev" {
  type = string
}

variable "traefik_internal_port_dev" {
  type = string
}

variable "traefik_public_ip_prod" {
  type = string
}

variable "traefik_public_port_prod" {
  type = string
}

variable "traefik_internal_ip_prod" {
  type = string
}

variable "traefik_internal_port_prod" {
  type = string
}
