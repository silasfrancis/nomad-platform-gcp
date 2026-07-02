variable "project_id" {
  type = string
}

variable "location" {
  type = string
}

variable "vault_vm_sa_member" {
  type    = string
  description = "The full IAM member string for the Vault VM's service account. Example: serviceAccount:vault-vm-sa@<project-id>.iam.gserviceaccount.com"
}