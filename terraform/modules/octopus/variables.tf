variable "gcp_project" {
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
