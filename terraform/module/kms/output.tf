output "key_rings" {
  description = "A map of KeyRing names to their resource IDs."
  value = {
    for name, keyring in google_kms_key_ring.this : name => keyring.id
  }
}

output "key_rings" {
  description = "A map of KeyRing names to their resource IDs."
  value = {
    for name, keyring in google_kms_key_ring.this : name => keyring.id
  }
}

output "kms_iam_bindings" {
  description = "Map of IAM bindings applied to crypto keys."
  value = {
    for name, binding in google_kms_crypto_key_iam_binding.this : name => {
      role    = binding.role
      members = binding.members
    }
  }
}