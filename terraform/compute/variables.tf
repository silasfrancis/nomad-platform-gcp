variable "project_id" {
  type = string
}

variable "region" {
  type = string
}

variable "active_environments" {
  description = "Which environments to actually provision. Start with [\"dev\"], test it, then add \"prod\" and re-apply. Resources not in this set are never created — not created-then-stopped, genuinely absent. mgmt-vm and other shared resources are unconditional and ignore this entirely."
  type        = set(string)
  default     = ["dev"]

  validation {
    condition     = alltrue([for e in var.active_environments : contains(["dev", "prod"], e)])
    error_message = "active_environments may only contain \"dev\" and/or \"prod\"."
  }
}

variable "nomad_dev_server_count" {
  description = "Number of Nomad dev servers (architecture doc allows 1-3; 1 is fine for a single-node Raft cluster with no HA)."
  type        = number
  default     = 1

  validation {
    condition     = var.nomad_dev_server_count >= 1 && var.nomad_dev_server_count <= 3
    error_message = "nomad_dev_server_count must be between 1 and 3."
  }
}
