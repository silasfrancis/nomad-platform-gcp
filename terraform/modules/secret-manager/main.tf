locals {
  # Merge baseline + net-new. var.secrets validation (in variables.tf) prevents
  # key collisions, so this merge is safe — no silent overwrite of defaults.
  secrets = merge(var.default_secrets, var.secrets)

  tier_accessor_members = {
    root  = var.root_tier_accessor_members
    admin = var.admin_tier_accessor_members
    app   = var.app_tier_accessor_members
  }

  # Inject tier-based secretAccessor members into each secret's iam map,
  # while preserving any custom roles (e.g. secretVersionAdder) a secret
  # already defines. Custom secretAccessor entries (if any) are appended
  # to the tier default rather than overwritten.
  secrets_with_iam = {
    for name, secret in local.secrets : name => merge(secret, {
      iam = merge(
        {
          "roles/secretmanager.secretAccessor" = {
            members = concat(
              lookup(local.tier_accessor_members, lookup(secret.labels, "tier", "app"), []),
              try(secret.iam["roles/secretmanager.secretAccessor"].members, [])
            )
          }
        },
        {
          for role, binding in secret.iam : role => binding
          if role != "roles/secretmanager.secretAccessor"
        }
      )
    })
  }

  secret_iam_members = flatten([
    for secret_name, secret in local.secrets_with_iam : [
      for role, binding in secret.iam : [
        for member in binding.members : {
          secret = secret_name
          role   = role
          member = member
        }
      ]
    ]
  ])
}

resource "google_secret_manager_secret" "secret" {
  for_each = local.secrets

  project   = var.project_id
  secret_id = each.key

  deletion_policy     = "PREVENT"
  deletion_protection = true

  replication {
    auto {
      customer_managed_encryption {
        kms_key_name = var.storage_cmek
      }
    }
  }

  labels = merge(
    var.labels,
    each.value.labels
  )

  lifecycle {
    ignore_changes = [version_aliases]
  }
}

resource "google_secret_manager_secret_iam_member" "member" {
  for_each = {
    for binding in local.secret_iam_members :
    "${binding.secret}-${binding.role}-${binding.member}" => binding
  }

  project   = var.project_id
  secret_id = google_secret_manager_secret.secret[each.value.secret].secret_id

  role   = each.value.role
  member = each.value.member
}
