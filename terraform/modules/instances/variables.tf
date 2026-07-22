variable "project_id" {
  type = string
}

variable "boot_disk_image" {
  description = "Image family for the boot disk, shared by every static VM unless an instance overrides it."
  type        = string
  default     = "debian-cloud/debian-12"
}

variable "disk_cmek_key" {
  description = "KMS key self-link for boot disk encryption (bootstrap's platform/disk-cmek)."
  type        = string
}

variable "instances" {
  description = "Map of static VMs to create. Key is used as the instance name. One entry per VM — nomad-prod-server's 3 instances are 3 separate map entries (nomad-prod-server-0/1/2), not a count, so each can be pinned to its own zone."
  type = map(object({
    machine_type            = string
    zone                     = string
    subnetwork               = string # self-link
    external_ip              = optional(bool, false)
    service_account_email    = string
    service_account_scopes   = optional(list(string), ["cloud-platform"])
    tags                     = optional(list(string), [])
    startup_script           = optional(string, "")
    shutdown_script          = optional(string, "")
    boot_disk_size_gb        = optional(number, 20)
    labels                   = optional(map(string), {})
  }))
}
