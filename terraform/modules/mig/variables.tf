variable "project_id" {
  type = string
}

variable "region" {
  type = string
}

variable "disk_cmek_key" {
  type = string
}

variable "zones" {
  description = "Zones this region's MIGs distribute across (regional/multi-zone, per architecture doc 1.3 — reduces Spot preemption risk since capacity pressure is typically zone-specific)."
  type        = list(string)
}

variable "migs" {
  description = "Map of MIGs to create. Add an entry to create another pool — template, MIG, and autoscaler all generate from one map, nothing else needs touching."
  type = map(object({
    environment             = string
    machine_type            = string
    subnetwork               = string # self-link
    min_replicas             = number
    max_replicas             = number
    spot                     = bool
    service_account_email    = string
    boot_disk_image          = optional(string,  "debian-cloud/debian-12")
    boot_disk_size_gb        = optional(number, 30)
    tags                     = optional(list(string), [])
    labels                   = optional(map(string), {})
    startup_script           = optional(string, "")
    # Ran on spot-preemption notice (ACPI G2 Soft Off), 30s before terminate.
    # Ignored for on-demand pools (spot = false).
    shutdown_script          = optional(string, "")
    cpu_target               = optional(number, 0.6) # doc: 60% average CPU

    # Re-add only for a pool with no matching Nomad Autoscaler policy.
    #
    #   scale_in_control = optional(object({
    #     max_scaled_in_replicas_fixed = optional(number, 1)
    #     time_window_sec              = optional(number, 300)
    #   }), null)
  }))
}
