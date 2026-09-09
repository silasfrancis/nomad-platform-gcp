locals {    
  bucket_defaults = {
    location                    = var.region
    storage_class               = "STANDARD"
    uniform_bucket_level_access = true
    public_access_prevention    = "enforced"
    force_destroy               = false
    deletion_policy             = "PREVENT"
    versioning_enabled          = true
    soft_delete_retention       = 604800
    kms_key_id                  = var.storage_cmek

    labels = merge(
      {
        managed-by = "terraform"
        team       = "platform"
      }, var.additional_labels
    )
  }

  default_bucket_iam = {
    "roles/storage.objectViewer"  = []
    "roles/storage.objectCreator" = []
  }

  bucket_iam_bindings = merge([
    for bucket_key, bucket in var.buckets : merge([
      for role, role_config in try(bucket.iam, {}) : {
        for member in toset(concat(
          coalesce(try(bucket.override_default_iam, null), false) ? [] : lookup(local.default_bucket_iam, role, []),
          role_config.members
        )) :
        "${bucket_key}/${replace(role, "roles/", "")}/${replace(replace(member, "serviceAccount:", ""), "user:", "")}" => {
          bucket_key  = bucket_key
          bucket_name = try(bucket.name_override, null) != null ? bucket.name_override : bucket_key
          role        = role
          member      = member
          condition   = try(role_config.condition, null)
        }
      }
    ]...)
  ]...)
}

resource "google_storage_bucket" "buckets" {
  for_each = var.buckets

  project       = var.project_id
  name          = try(each.value.name_override, null) != null ? each.value.name_override : each.key
  location      = local.bucket_defaults.location

  storage_class               = try(each.value.storage_class, local.bucket_defaults.storage_class)
  uniform_bucket_level_access = try(each.value.uniform_bucket_level_access, local.bucket_defaults.uniform_bucket_level_access)
  public_access_prevention    = try(each.value.public_access_prevention, local.bucket_defaults.public_access_prevention)
  force_destroy               = try(each.value.force_destroy, local.bucket_defaults.force_destroy)
  deletion_policy             = try(each.value.deletion_policy, local.bucket_defaults.deletion_policy)

  labels = merge(
    local.bucket_defaults.labels,
    { environment = try(each.value.labels.environment, var.environment) },
    try(each.value.labels, {})
  )

  encryption {
    default_kms_key_name = coalesce(try(each.value.kms_key_id, null), local.bucket_defaults.kms_key_id)
    google_managed_encryption_enforcement_config {
        restriction_mode = "FullyRestricted"
    }
    customer_supplied_encryption_enforcement_config {
        restriction_mode = "FullyRestricted"
    }
  }
  
  versioning {
    enabled = coalesce(try(each.value.versioning_enabled, null), local.bucket_defaults.versioning_enabled)
  }

  soft_delete_policy {
    retention_duration_seconds = try(each.value.soft_delete_retention, local.bucket_defaults.soft_delete_retention)
  }

  dynamic "lifecycle_rule" {
    for_each = try(each.value.enable_tiering, false) ? [1] : []
    content {
      condition {
        age                   = 30
        with_state            = "LIVE"
        matches_storage_class = ["STANDARD"]
      }
      action {
        type          = "SetStorageClass"
        storage_class = "NEARLINE"
      }
    }
  }

  dynamic "lifecycle_rule" {
    for_each = try(each.value.enable_tiering, false) ? [1] : []
    content {
      condition {
        age                   = 90
        with_state            = "LIVE"
        matches_storage_class = ["NEARLINE"]
      }
      action {
        type          = "SetStorageClass"
        storage_class = "COLDLINE"
      }
    }
  }

  lifecycle_rule {
    condition {
      age        = try(each.value.backup_retention_days, 30)
      with_state = "LIVE"
    }
    action {
      type = "Delete"
    }
  }

  lifecycle_rule {
    condition {
      days_since_noncurrent_time = 7
      with_state                 = "ARCHIVED"
    }
    action {
      type = "Delete"
    }
  }

  lifecycle_rule {
    condition {
      age = 7
    }
    action {
      type = "AbortIncompleteMultipartUpload"
    }
  }

  dynamic "logging" {
    for_each = try(each.value.logging.enabled, false) ? [1] : []
    content {
      log_bucket        = each.value.logging.log_bucket
      log_object_prefix = each.value.logging.prefix
    }
  }
}

resource "google_storage_bucket_iam_member" "bucket_iam" {
  for_each = local.bucket_iam_bindings

  bucket = each.value.bucket_name
  role   = each.value.role
  member = each.value.member

  dynamic "condition" {
    for_each = each.value.condition != null ? [each.value.condition] : []

    content {
      title       = condition.value.title
      description = try(condition.value.description, null)
      expression  = condition.value.expression
    }
  }

  depends_on = [
    google_storage_bucket.buckets
  ]
}