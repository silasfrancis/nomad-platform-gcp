variable "project_id" {
  type = string
}


variable "project_number" {
  type = string
}

variable "location" {
  type = string
}

variable "crypto_key_iam" {
  description = <<-EOT
    IAM members per KMS key, keyed by "<keyring>/<key>" (must match an
    entry in local.kms_keyrings) and then by role. Each role's members
    list becomes an authoritative binding for that role on that key —
    unlike the secret-manager module, this is a flat per-role grant, not
    a tier system, since KMS keys don't have a uniform access pattern
    across an entire tier the way secrets do.

    Example — granting a VM both crypto operations and existence checks
    on the same key (Vault's gcpckms seal needs both):
      crypto_key_iam = {
        "vault-unseal/vault-unseal-cmek" = {
          "roles/cloudkms.cryptoKeyEncrypterDecrypter" = {
            members = ["serviceAccount:management-vm-sa@project.iam.gserviceaccount.com"]
          }
          "roles/cloudkms.viewer" = {
            members = ["serviceAccount:management-vm-sa@project.iam.gserviceaccount.com"]
          }
        }
      }

    Custom/non-predefined roles work the same way — just use the full
    custom role ID as the map key, e.g.
    "projects/PROJECT/roles/myCustomKmsRole".
  EOT
  type = map(map(object({
    members    = list(string)
    condition  = optional(object({
      title       = string
      description = optional(string)
      expression  = string
    }))
  })))
  default = {}

  validation {
    condition = length([
      for key_ref in keys(var.crypto_key_iam) : key_ref
      if !contains(keys({
        "vault-unseal/vault-unseal-cmek" = true
        "platform/storage-cmek"          = true
        "platform/disk-cmek"             = true
        "secrets/secrets-cmek"           = true
      }), key_ref)
    ]) == 0
    error_message = "One or more keys in var.crypto_key_iam don't match a defined \"<keyring>/<key>\" entry in local.kms_keyrings. Check for typos."
  }
}