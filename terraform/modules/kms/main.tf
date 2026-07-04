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

  # ── Default KMS key members ───────────────────────────────────────────────
  # GCP service agents that always need access to specific keys.
  # These are hardcoded because they are GCP-internal — they never change
  # and are not environment-specific.
  # Extra members (e.g. SA emails) are passed via var.crypto_key_extra_members
  # and merged in crypto_key_iam below.
  default_crypto_key_members = {
    "platform/storage-cmek" = [
      "serviceAccount:service-${var.project_number}@gs-project-accounts.iam.gserviceaccount.com",
      "serviceAccount:service-${var.project_number}@gcp-sa-artifactregistry.iam.gserviceaccount.com",
      "serviceAccount:service-${var.project_number}@gcp-sa-secretmanager.iam.gserviceaccount.com",
    ]
    "platform/disk-cmek" = [
      "serviceAccount:service-${var.project_number}@compute-system.iam.gserviceaccount.com",
    ]
    "vault-unseal/vault-unseal-cmek" = []
    # No default members for vault-unseal — only management-vm-sa needs it,
    # passed via var.vault_unseal_key_members
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
  }
}
# ── KMS keyrings ──────────────────────────────────────────────────────────────
# One resource per keyring in local.kms_keyrings.
# Keyrings cannot be deleted once created in GCP — they can only be emptied.
# Terraform tracks them in state but deletion_policy on the keys (below)
# prevents the keys themselves from being destroyed.

resource "google_kms_key_ring" "this" {
  for_each = local.kms_keyrings

  project  = var.project_id
  name     = each.key
  location = var.region
}

# ── KMS crypto keys ───────────────────────────────────────────────────────────
# Indexed by kms_keys_flat: "<keyring>/<key>" → { keyring, key, purpose, rotation_period }
# key_ring references google_kms_key_ring.this by keyring name — Terraform
# infers the dependency automatically from this reference.

resource "google_kms_crypto_key" "keys" {
  for_each = local.kms_keys_flat

  name            = each.value.key
  key_ring        = google_kms_key_ring.this[each.value.keyring].id
  purpose         = each.value.purpose
  rotation_period = each.value.rotation_period

  # PREVENT: Terraform refuses to delete this key even on terraform destroy.
  # Keys protecting live data (Vault unseal, GCS buckets, persistent disks)
  # must never be accidentally destroyed — doing so makes encrypted data
  # permanently unrecoverable.
  deletion_policy = "PREVENT"

  version_template {
    algorithm        = "GOOGLE_SYMMETRIC_ENCRYPTION"
    protection_level = "SOFTWARE"
    # SOFTWARE: key material stored in GCP's software HSM.
    # HSM protection_level is available if hardware compliance is required
    # but costs significantly more. SOFTWARE is appropriate for this project.
  }

  lifecycle {
    prevent_destroy = true
  }
}

# ── KMS key IAM bindings ──────────────────────────────────────────────────────
# Uses iam_binding (not iam_member) — Terraform is authoritative for the
# complete member list on this role for this key. Any member not in the
# members list is removed on next apply.
#
# This is intentional for encryption keys: if someone manually grants
# cryptoKeyEncrypterDecrypter in the GCP console, the next terraform apply
# removes them. Terraform is the single source of truth for key access.
#
# crypto_key_id references google_kms_crypto_key.keys by its flat map key
# ("keyring/key" format) which is identical to the crypto_key_iam map key —
# both use local.kms_keys_flat as their source so the keys always match.

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

# ── KMS keyring IAM bindings ──────────────────────────────────────────────────
# Keyring-level bindings grant access to ALL keys in the ring.
# Empty by default (key_ring_iam = {}) — no resources created unless
# a keyring-level binding is explicitly added to local.key_ring_iam.
# Prefer key-level bindings above for least-privilege access.

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