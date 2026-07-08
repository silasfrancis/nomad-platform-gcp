variable "project_id" {
  type = string
}

variable "region" {
  type = string
}

variable "disk_cmek_key" {
  type = string
}

variable "boot_disk_image" {
  type    = string
  default = "debian-cloud/debian-12"
}

variable "zones" {
  description = "Zones this region's MIGs distribute across (regional/multi-zone, per architecture doc 1.3 — reduces Spot preemption risk since capacity pressure is typically zone-specific)."
  type        = list(string)
}

variable "migs" {
  description = "Map of MIGs to create. Add an entry to create another pool — template, MIG, and autoscaler all generate from one map, nothing else needs touching."
  type = map(object({
    machine_type            = string
    subnetwork               = string # self-link
    min_replicas             = number
    max_replicas             = number
    spot                     = bool
    service_account_email    = string
    boot_disk_size_gb        = optional(number, 30)
    tags                     = optional(list(string), [])
    labels                   = optional(map(string), {})
    startup_script           = optional(string, "")
    # Ran on spot-preemption notice (ACPI G2 Soft Off), 30s before terminate.
    # Ignored for on-demand pools (spot = false).
    shutdown_script          = optional(string, "")
    cpu_target               = optional(number, 0.6) # doc: 60% average CPU
  }))
}
