output "key_rings" {
  description = "A map of KeyRing names to their resource IDs."
  value = {
    for name, keyring in google_kms_key_ring.this : name => keyring.id
  }
}

output "kms_keys" {
  description = "A map of KMS key names to their resource IDs."
  value = {
    for key_ref, key in google_kms_crypto_key.keys : key_ref => {
      id   = key.id
      name = key.name
    }
  }
}

output "kms_key_access_control" {
  description = "A summary of the KMS keys and the service accounts authorized to use them."
  value = {
    for key_ref, iam in google_kms_crypto_key_iam_binding.this : 
    key_ref => {
      role    = iam.role
      members = iam.members
    }
  }
}