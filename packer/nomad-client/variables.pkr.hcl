variable "project_id" {
  type        = string
  description = "GCP project ID to build the image in."
}

variable "disk_cmek_key_id" {
  type        = string
  description = "Full self-link of disk-cmek from terraform/bootstrap's outputs — matches the boot disk encryption policy used everywhere else in this project."
}

variable "zone" {
  type        = string
  default     = "us-central1-a"
  description = "Zone for the ephemeral build VM. Doesn't need to match where the real instances run — this VM is torn down right after the image is created."
}

variable "subnetwork" {
  type        = string
  default     = "subnet-mgmt"
  description = "Build VM lives on subnet-mgmt — no dedicated build subnet, reusing mgmt's since network/ is already locked and iap-ssh already covers it (see session notes on this decision)."
}

variable "service_account_email" {
  type        = string
  description = "packer-builder-sa's email, from terraform/bootstrap's outputs (packer_builder_sa_email)."
}

variable "ssh_username" {
  type        = string
  default     = "packer"
  description = "With use_os_login = true, Packer typically derives the actual login username from the authenticating identity's OS Login profile rather than using this value verbatim — this default hasn't been confirmed against a real build. Verify the actual connecting username in a test run before relying on this."
}
