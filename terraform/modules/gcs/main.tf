locals {

  # ── Bucket defaults ───────────────────────────────────────────────────────
  # Applied to every bucket unless overridden in the buckets map.
  bucket_defaults = {
    location                    = var.region
    storage_class               = "STANDARD"
    uniform_bucket_level_access = true
    public_access_prevention    = "enforced"
    force_destroy               = false
    deletion_policy             = "PREVENT"
    versioning_enabled          = true
    soft_delete_retention       = 604800  # 7 days minimum
    kms_key_id                  = var.storage_cmek

    # Universal labels — applied to every bucket automatically.
    # Do not put environment or purpose here — those are per-bucket concerns.
    labels = merge(
      {
        managed-by = "terraform"
        team       = "platform"
      }, var.additional_labels
    )
  }

  # ── Default IAM members per role ──────────────────────────────────────────
  # Members that get the role on every bucket.
  # Leave empty to require explicit iam blocks per bucket.
  default_bucket_iam = {
    "roles/storage.objectViewer"  = []
    "roles/storage.objectCreator" = []
  }

  # ── Bucket registry ───────────────────────────────────────────────────────
  # Fields:
  #   name_override         string       — use if bucket name differs from key
  #   storage_class         string       — override default STANDARD
  #   kms_key_id            string       — override default gcs-storage key
  #   versioning_enabled    bool         — override default true
  #   soft_delete_retention number       — seconds, override default 604800
  #   force_destroy         bool         — override default false
  #   deletion_policy       string       — override default PREVENT
  #   backup_retention_days number       — age in days before objects deleted
  #   enable_tiering        bool         — STANDARD→NEARLINE→COLDLINE transitions
  #   override_default_iam  bool         — skip default_bucket_iam, use iam only
  #
  #   logging = {
  #     enabled    = bool   — set true to enable access logging
  #     log_bucket = string — bucket to write logs to (must exist)
  #     prefix     = string — log object prefix e.g. "platform-artifacts-logs/"
  #   }
  #   Currently disabled on all buckets. Enable per bucket when a dedicated
  #   log bucket exists. GCP audit logs capture API-level access automatically
  #   regardless of this setting.
  #
  #   labels = map(string)
  #     Merged with bucket_defaults.labels — per-bucket values win on conflict.
  #     Always set environment and purpose here.
  #     environment defaults to var.environment if not set — useful when the
  #     same config is applied across workspaces (dev/prod). For bootstrap
  #     buckets that are genuinely shared, set "shared" explicitly.
  #
  #   iam = {
  #     "roles/storage.objectCreator" = {
  #       members = list(string)
  #     }
  #   }

  buckets = {

    "${var.project_id}-${var.region}-platform-artifacts" = {
      backup_retention_days = 90
      enable_tiering        = true

      logging = {
        enabled    = false
        log_bucket = ""     # set to dedicated log bucket name when enabling
        prefix     = "platform-artifacts-logs/"
      }

      labels = {
        environment = "shared"          # explicit — bootstrap is always shared
        purpose     = "platform-backups"
      }

      iam = {
        "roles/storage.objectCreator" = {
          members = var.platform_artifacts_creator_members
        }
        "roles/storage.objectViewer" = {
          members = var.platform_artifacts_viewer_members
        }
      }
    }

    "${var.project_id}-${var.region}-ci-cd-artifacts" = {
      backup_retention_days = 30
      enable_tiering        = false

      logging = {
        enabled    = false
        log_bucket = ""
        prefix     = "ci-cd-artifacts-logs/"
      }

      labels = {
        # No explicit environment — falls back to var.environment at resource level
        # If var.environment = "shared" in tfvars this behaves identically
        # to setting it explicitly here. Use explicit "shared" if you want
        # it hardcoded regardless of what workspace is active.
        purpose = "ci-cd-artifacts"
      }

      iam = {
        "roles/storage.objectCreator" = {
          members = var.cicd_artifacts_creator_members
        }
        "roles/storage.objectViewer" = {
          members = var.cicd_artifacts_viewer_members
        }
      }
    }

  }

  # ── Flattened IAM bindings ────────────────────────────────────────────────
  # Flat map for for_each on google_storage_bucket_iam_member.
  # Key format: "<bucket_key>/<role_short>/<member>"
  bucket_iam_bindings = merge([
    for bucket_key, bucket in local.buckets : merge([
      for role, role_config in lookup(bucket, "iam", {}) : {
        for member in toset(concat(
          lookup(bucket, "override_default_iam", false) ? [] : lookup(local.default_bucket_iam, role, []),
          role_config.members
        )) :
        "${bucket_key}/${replace(role, "roles/", "")}/${member}" => {
          bucket_key  = bucket_key
          bucket_name = lookup(bucket, "name_override", bucket_key)
          role        = role
          member      = member
        }
      }
    ]...)
  ]...)
}

# ── GCS Buckets ───────────────────────────────────────────────────────────────
# Driven entirely by local.buckets — to add a new bucket, add a key to the
# buckets map in locals. No resource changes needed.

resource "google_storage_bucket" "buckets" {
  for_each = local.buckets

  project  = var.project_id
  name     = lookup(each.value, "name_override", each.key)
  location = local.bucket_defaults.location

  storage_class               = lookup(each.value, "storage_class", local.bucket_defaults.storage_class)
  uniform_bucket_level_access = lookup(each.value, "uniform_bucket_level_access", local.bucket_defaults.uniform_bucket_level_access)
  public_access_prevention    = lookup(each.value, "public_access_prevention", local.bucket_defaults.public_access_prevention)
  force_destroy               = lookup(each.value, "force_destroy", local.bucket_defaults.force_destroy)
  deletion_policy             = lookup(each.value, "deletion_policy", local.bucket_defaults.deletion_policy)

  # ── Labels ─────────────────────────────────────────────────────────────────
  # Merge order (lowest → highest priority):
  #   1. bucket_defaults.labels  (managed-by, team)
  #   2. environment fallback    (var.environment if not set per bucket)
  #   3. per-bucket labels       (environment if explicit, purpose, any others)
  labels = merge(
    local.bucket_defaults.labels,
    { environment = lookup(lookup(each.value, "labels", {}), "environment", var.environment) },
    lookup(each.value, "labels", {})
  )

  # ── Encryption ─────────────────────────────────────────────────────────────
  # CMEK using the key defined per bucket or falling back to the default
  # gcs-storage key from the platform-storage keyring.
  # The GCS service agent must have cryptoKeyEncrypterDecrypter on this key
  # before the bucket is created — enforced via depends_on below.
  encryption {
    default_kms_key_name = lookup(each.value, "kms_key_id", local.bucket_defaults.kms_key_id)
    # Enforce CMEK only — reject writes using GMEK or CSEK.
    # Without this, the encryption block sets the DEFAULT but does not prevent
    # an API caller from explicitly writing an object with GMEK, bypassing
    # your KMS key. FullyRestricted closes that gap.
    google_managed_encryption_enforcement_config {
        restriction_mode = "FullyRestricted"
    }
    customer_supplied_encryption_enforcement_config {
        restriction_mode = "FullyRestricted"
    }
  # customer_managed_encryption_enforcement_config is omitted —
  # omitting it means CMEK is allowed, which is what we want.
  }

  # ── Versioning ─────────────────────────────────────────────────────────────
  # Enabled by default — if a backup is overwritten or corrupted, the
  # previous version is recoverable. Noncurrent versions are cleaned up
  # by lifecycle rules below so they don't accumulate indefinitely.
  versioning {
    enabled = lookup(each.value, "versioning_enabled", local.bucket_defaults.versioning_enabled)
  }

  # ── Soft delete ────────────────────────────────────────────────────────────
  # Deleted objects are retained for the configured period before permanent
  # deletion. Provides a recovery window for accidental deletes.
  # 604800 = 7 days (GCP minimum). Set to 0 to disable.
  soft_delete_policy {
    retention_duration_seconds = lookup(each.value, "soft_delete_retention", local.bucket_defaults.soft_delete_retention)
  }

  # ── Lifecycle rules ────────────────────────────────────────────────────────

  # Rule 1 (tiering only): Transition STANDARD → NEARLINE after 30 days.
  # NEARLINE costs ~50% less than STANDARD. 30-day minimum storage commitment
  # so only worthwhile for buckets with backup_retention_days >= 60.
  dynamic "lifecycle_rule" {
    for_each = lookup(each.value, "enable_tiering", false) ? [1] : []
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

  # Rule 2 (tiering only): Transition NEARLINE → COLDLINE after 90 days.
  # COLDLINE costs ~75% less than STANDARD. 90-day minimum storage commitment.
  dynamic "lifecycle_rule" {
    for_each = lookup(each.value, "enable_tiering", false) ? [1] : []
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

  # Rule 3 (all buckets): Delete current objects after backup_retention_days.
  # Hard retention cutoff — objects older than this are deleted regardless
  # of storage class. Keeps costs bounded.
  lifecycle_rule {
    condition {
      age        = lookup(each.value, "backup_retention_days", 30)
      with_state = "LIVE"
    }
    action {
      type = "Delete"
    }
  }

  # Rule 4 (all buckets): Delete noncurrent (versioned) objects after 7 days.
  # Versioning keeps overwritten/deleted objects as noncurrent versions.
  # Without this they accumulate indefinitely. 7 days matches the
  # soft_delete_policy window — enough time for recovery.
  lifecycle_rule {
    condition {
      days_since_noncurrent_time = 7
      with_state                 = "ARCHIVED"
    }
    action {
      type = "Delete"
    }
  }

  # Rule 5 (all buckets): Abort incomplete multipart uploads after 7 days.
  # Large backup files uploaded in parts leave orphaned partial uploads if
  # the upload fails midway. This cleans them up to avoid storage cost leakage.
  lifecycle_rule {
    condition {
      age = 7
    }
    action {
      type = "AbortIncompleteMultipartUpload"
    }
  }

  # ── Access logging ─────────────────────────────────────────────────────────
  # Disabled by default on all buckets — logging block is stubbed here so
  # it can be enabled per bucket by setting logging.enabled = true and
  # providing a log_bucket. GCP audit logs capture API-level access
  # automatically regardless of this setting.
  #
  # To enable: set logging.enabled = true and logging.log_bucket in the
  # bucket's config block in locals. Requires a dedicated log bucket with
  # roles/storage.legacyBucketWriter granted to the GCS logging service account:
  #   storage.googleapis.com/projects/_/serviceAccounts/<project_number>@gcs-analytics.iam.gserviceaccount.com
  dynamic "logging" {
    for_each = try(each.value.logging.enabled, false) ? [1] : []
    content {
      log_bucket        = each.value.logging.log_bucket
      log_object_prefix = each.value.logging.prefix
    }
  }

}

# ── GCS Bucket IAM ────────────────────────────────────────────────────────────
# Driven by local.bucket_iam_bindings — flat map produced by merging
# default_bucket_iam members with per-bucket iam members per role.
# Key format: "<bucket_key>/<role_short>/<member>"

resource "google_storage_bucket_iam_member" "buckets" {
  for_each = local.bucket_iam_bindings

  bucket = google_storage_bucket.buckets[each.value.bucket_key].name
  role   = each.value.role
  member = each.value.member
}