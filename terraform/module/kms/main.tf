locals {
  kms_keyrings = {
    "vault-unseal" = {
      keys = {
        "vault-unseal-key" = {
          purpose         = "ENCRYPT_DECRYPT"
          rotation_period = "31536000s"
        }
      }
    }
    "platform-storage" = {
      keys = {
        "gcs-storage" = {
          purpose         = "ENCRYPT_DECRYPT"
          rotation_period = "7776000s"
        }
        "persistent-disk" = {
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

  default_condition = {
    title       = null
    description = null
    expression  = null
  }
  
  key_ring_iam = {}

  crypto_key_iam = {
    "gcs-storage-agent" = {
      key_ref = "platform-storage/gcs-storage"
      role    = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
      member  = ["serviceAccount:service-${var.project_id}@gs-project-accounts.iam.gserviceaccount.com"]
      condition = merge(local.default_condition, {})
    }
    "compute-disk-agent" = {
      key_ref = "platform-storage/persistent-disk"
      role    = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
      member  = ["serviceAccount:service-${var.project_id}@compute-system.iam.gserviceaccount.com"]
      condition = merge(local.default_condition, {})
    }
    "vault-unseal-mgmt-vm" = {
      key_ref = "vault-unseal/vault-unseal-key"
      role    = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
      member  = [var.vault_vm_sa_member]
      condition = merge(local.default_condition, {})
    }
  }
}

resource "google_kms_key_ring" "this" {
  for_each = local.kms_keyrings
  project  = var.project_id
  name     = each.key
  location = var.location
}

resource "google_kms_crypto_key" "keys" {
  for_each        = local.kms_keys_flat
  name            = each.value.key
  key_ring        = google_kms_key_ring.this[each.value.keyring].id
  purpose         = each.value.purpose
  rotation_period = each.value.rotation_period
  deletion_policy = "PREVENT"

  version_template {
    algorithm        = "GOOGLE_SYMMETRIC_ENCRYPTION"
    protection_level = "SOFTWARE"
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_kms_crypto_key_iam_binding" "this" {
  for_each = local.crypto_key_iam

  crypto_key_id = google_kms_crypto_key.keys[each.value.key_ref].id
  role          = each.value.role
  members       = each.value.members

  dynamic "condition" {
      for_each = each.value.condition.expression != null ? [each.value.condition] : []
      content {
        title       = condition.value.title
        description = condition.value.description
        expression  = condition.value.expression
      }
    }
}