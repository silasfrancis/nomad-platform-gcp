variable "project_id" {
  type = string
}


variable "project_number" {
  type = string
}

variable "location" {
  type = string
}

variable "crypto_key_members" {
  description = <<-EOT
    Extra IAM members to add to specific KMS keys, merged with the default
    service agent members. Map key must match a "<keyring>/<key>" entry
    in local.kms_keyrings.

    Use this to add SA emails or groups without touching locals:
      crypto_key_extra_members = {
        "platform/disk-cmek" = [
          "serviceAccount:some-other-sa@project.iam.gserviceaccount.com"
        ]
      }

    Role is inherited from the crypto_key_iam entry for that key —
    all extra members get the same role as the default members.
    If you need a different role on the same key, add a separate
    crypto_key_iam entry with a unique binding name.
  EOT
  type    = map(list(string))
  default = {}
}