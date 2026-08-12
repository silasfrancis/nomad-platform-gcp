locals {
  kms_keyrings = {
    "vault-unseal" = {
      keys = {
        "vault-unseal-cmek" = {
          purpose         = "ENCRYPT_DECRYPT"
          rotation_period = "31536000s"
        }
      }
    }
    "platform" = {
      keys = {
        "storage-cmek" = {
          purpose         = "ENCRYPT_DECRYPT"
          rotation_period = "7776000s"
        }
        "disk-cmek" = {
          purpose         = "ENCRYPT_DECRYPT"
          rotation_period = "7776000s"
        }
      }
    }
    "secrets" = {
      keys = {
        "secrets-cmek" = {
          purpose         = "ENCRYPT_DECRYPT"
          rotation_period = "7776000s"
        }
      }
    }
  }

  # Flattened map of keyring/key → key config
  # Built from kms_keyrings so there is only one source of truth.
  # Format: "<keyring>/<key>" = { purpose, rotation_period }
  # Used to resolve key IDs in IAM bindings
  # without repeating keyring+key names.
  kms_keys_flat = merge([
    for keyring_name, keyring in local.kms_keyrings : {
      for key_name, key_config in keyring.keys :
      "${keyring_name}/${key_name}" => merge(key_config, {
        keyring = keyring_name
        key     = key_name
      })
    }
  ]...)

  default_crypto_key_members = {
    "platform/storage-cmek"           = []
    "platform/disk-cmek"              = []
    "vault-unseal/vault-unseal-cmek"  = []
    "secrets/secrets-cmek"            = []
  }
  
  key_ring_iam_bindings = {}
  crypto_key_iam = {
    "platform/storage-cmek" = {
      role = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
      members = toset(concat(
        local.default_crypto_key_members["platform/storage-cmek"],
        lookup(var.crypto_key_members, "platform/storage-cmek", [])
      ))
      condition = {
        title       = null
        description = null
        expression  = null
      }
    }

    "platform/disk-cmek" = {
      role = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
      members = toset(concat(
        local.default_crypto_key_members["platform/disk-cmek"],
        lookup(var.crypto_key_members, "platform/disk-cmek", [])
      ))
      condition = {
        title       = null
        description = null
        expression  = null
      }
    }

    "vault-unseal/vault-unseal-cmek" = {
      role = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
      members = toset(concat(
        local.default_crypto_key_members["vault-unseal/vault-unseal-cmek"],
        lookup(var.crypto_key_members, "vault-unseal/vault-unseal-cmek", [])
      ))
      condition = {
        title       = null
        description = null
        expression  = null
      }
    }

    "secrets/secrets-cmek" = {
      role = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
      members = toset(concat(
        local.default_crypto_key_members["secrets/secrets-cmek"],
        lookup(var.crypto_key_members, "secrets/secrets-cmek", [])
      ))
      condition = {
        title       = null
        description = null
        expression  = null
      }
    }
  }
}

resource "google_kms_key_ring" "this" {
  for_each = local.kms_keyrings

  project  = var.project_id
  name     = each.key
  location = each.key == "secrets" ? "global" : var.location
}

resource "google_kms_crypto_key" "keys" {
  for_each = local.kms_keys_flat

  name            = each.value.key
  key_ring        = google_kms_key_ring.this[each.value.keyring].id
  purpose         = each.value.purpose
  rotation_period = each.value.rotation_period
  deletion_policy = "DELETE"

  version_template {
    algorithm        = "GOOGLE_SYMMETRIC_ENCRYPTION"
    protection_level = "SOFTWARE"
  }

  # lifecycle {
  #   prevent_destroy = true
  # }
}

resource "google_kms_crypto_key_iam_binding" "this" {
  for_each = local.crypto_key_iam

  crypto_key_id = google_kms_crypto_key.keys[each.key].id
  role          = each.value.role
  members       = each.value.members

  # Condition block only created when expression is non-null.
  # Sending an empty condition block to the GCP API causes a validation error.
  dynamic "condition" {
    for_each = each.value.condition.expression != null ? [each.value.condition] : []
    content {
      title       = condition.value.title
      description = condition.value.description
      expression  = condition.value.expression
    }
  }
}

resource "google_kms_key_ring_iam_binding" "this" {
  for_each = local.key_ring_iam_bindings

  key_ring_id = google_kms_key_ring.this[each.value.keyring].id
  role        = each.value.role
  members     = each.value.members

  dynamic "condition" {
    for_each = each.value.condition.expression != null ? [each.value.condition] : []
    content {
      title       = condition.value.title
      description = condition.value.description
      expression  = condition.value.expression
    }
  }
}