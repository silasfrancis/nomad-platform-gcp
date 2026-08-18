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

  kms_keys_flat = merge([
    for keyring_name, keyring in local.kms_keyrings : {
      for key_name, key_config in keyring.keys :
      "${keyring_name}/${key_name}" => merge(key_config, {
        keyring = keyring_name
        key     = key_name
      })
    }
  ]...)

  # Flatten var.crypto_key_iam from key_ref -> role -> {members, condition}
  # into one entry per key×role binding, keyed by "<key_ref>__<role>" so
  # each role gets its own google_kms_crypto_key_iam_binding resource —
  # this is what lets a single key carry multiple roles simultaneously.
  crypto_key_iam_flat = merge([
    for key_ref, roles in var.crypto_key_iam : {
      for role, binding in roles :
      "${key_ref}__${role}" => {
        key_ref   = key_ref
        role      = role
        members   = toset(binding.members)
        condition = binding.condition
      }
    }
  ]...)

  key_ring_iam_bindings = {}
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
}

resource "google_kms_crypto_key_iam_binding" "this" {
  for_each = local.crypto_key_iam_flat

  crypto_key_id = google_kms_crypto_key.keys[each.value.key_ref].id
  role          = each.value.role
  members       = each.value.members

  dynamic "condition" {
    for_each = each.value.condition != null ? [each.value.condition] : []
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