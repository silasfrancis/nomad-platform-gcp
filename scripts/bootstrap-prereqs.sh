#!/bin/bash
# scripts/bootstrap-prereqs.sh
#
# One-time setup that must happen BEFORE terraform init can run.
# Everything else is handled by Terraform — do not add to this script
# unless it genuinely cannot be managed by Terraform due to a
# chicken-and-egg dependency.
#
# Three things live here:
#   1. Enable cloudresourcemanager API  — Terraform cannot enable APIs without it
#   2. Create GCS state bucket          — Terraform cannot init without a backend
#   3. Configure state bucket settings  — must be production-grade from day one
#      since state files are written immediately on terraform init
#
# Run once per project, before anything else:
#   chmod +x scripts/bootstrap-prereqs.sh
#   ./scripts/bootstrap-prereqs.sh <project_id> <state_bucket> [region]
#
# After this completes:
#   cd terraform/bootstrap && terraform init && terraform apply -var-file=dev.tfvars
#
# After terraform apply completes, run:
#   ./scripts/apply-cmek-to-state-bucket.sh <project_id> <state_bucket>

set -euo pipefail

# ── Args ──────────────────────────────────────────────────────────────────────

PROJECT_ID="${1:-}"
REGION="${2:-europe-west1}"
STATE_BUCKET="${3:-}"

if [[ -z "$PROJECT_ID" || -z "$STATE_BUCKET" ]]; then
  echo "Usage: $0 <project_id> [region] <state_bucket_name> "
  echo "Example: $0 nomad-platform-gcp europe-west1 tfstate"
  exit 1
fi

echo "==> Project:      $PROJECT_ID"
echo "==> Region:       $REGION"
echo "==> State bucket: gs://$PROJECT_ID-$REGION-$STATE_BUCKET"
echo ""

# ── Step 1: Set active project ────────────────────────────────────────────────

echo "==> [1/4] Setting active project"
gcloud config set project "$PROJECT_ID"

# ── Step 2: Enable cloudresourcemanager API ───────────────────────────────────
# Must be enabled before Terraform can enable any other API.
# This is the only API that cannot be managed by Terraform because
# Terraform needs it to manage APIs — classic chicken-and-egg.

echo "==> [2/4] Enabling cloudresourcemanager API"
gcloud services enable cloudresourcemanager.googleapis.com
echo "    Done."

# ── Step 3: Create state bucket ───────────────────────────────────────────────
# State files are written on the very first terraform init, so the bucket must be correctly
# configured before Terraform ever touches it.
#
# Notable differences from platform-artifacts bucket used for applications:
#   - NO lifecycle deletion rule — state files are never automatically deleted
#   - Versioning enabled — critical for state rollback on failed applies
#   - Soft delete 7 days — recovery window for accidental state deletion
#   - No CMEK yet — applied by apply-cmek-to-state-bucket.sh after bootstrap
#     creates the KMS key. Until then GCS uses Google-managed encryption.
#   - retention_period not set — we want state files to be mutable
#     (Terraform overwrites state on every apply)

echo "==> [3/4] Creating Terraform state bucket: gs://$PROJECT_ID-$REGION-$STATE_BUCKET"

# Check if bucket already exists to make script idempotent
if gcloud storage buckets describe "gs://$PROJECT_ID-$REGION-$STATE_BUCKET" &>/dev/null; then
  echo "    Bucket already exists — skipping creation."
else
  gcloud storage buckets create "gs://$PROJECT_ID-$REGION-$STATE_BUCKET" \
    --location="$REGION" \
    --uniform-bucket-level-access \
    --public-access-prevention
  echo "    Bucket created."
fi

# ── Step 4: Configure bucket settings ────────────────────────────────────────
# Applied separately from creation because some flags cannot be set at
# creation time (versioning, soft delete, labels).

echo "==> [4/4] Configuring state bucket"

# Versioning — keeps every version of every state file.
# On a failed terraform apply that corrupts state, you can restore the
# previous version: gcloud storage cp gs://<bucket>/path#<generation> ./terraform.tfstate
gcloud storage buckets update "gs://$PROJECT_ID-$REGION-$STATE_BUCKET" \
  --versioning

# Soft delete — 7 days recovery window before permanent deletion.
# Protects against accidental gsutil rm or gcloud storage rm on state files.
gcloud storage buckets update "gs://$PROJECT_ID-$REGION-$STATE_BUCKET" \
  --soft-delete-duration=604800s

# Labels — consistent with Terraform-managed resources.
# environment=shared: state bucket serves all environments (dev + prod workspaces)
gcloud storage buckets update "gs://$PROJECT_ID-$REGION-$STATE_BUCKET" \
  --update-labels=managed-by=terraform,team=platform,environment=shared,purpose=terraform-state

# Lifecycle rule — clean up noncurrent (old) state versions after 90 days.
LIFECYCLE_FILE=$(mktemp)
cat <<'EOF' > "$LIFECYCLE_FILE"
{
  "rule": [
    {
      "action": {
        "type": "Delete"
      },
      "condition": {
        "daysSinceNoncurrentTime": 90,
        "isLive": false
      }
    },
    {
      "action": {
        "type": "AbortIncompleteMultipartUpload"
      },
      "condition": {
        "age": 7
      }
    }
  ]
}
EOF

gcloud storage buckets update "gs://$PROJECT_ID-$REGION-$STATE_BUCKET" \
  --lifecycle-file="$LIFECYCLE_FILE"

rm -f "$LIFECYCLE_FILE"

echo "    Configuration complete."
echo ""
echo "============================================================"
echo "Prerequisites complete. Next steps:"
echo ""
echo "  1. cd terraform/bootstrap"
echo "  2. terraform init -backend-config="state.conf" -reconfigure"
echo "  3. terraform plan -out=tfplan"
echo "  4. terraform apply tfplan"
echo "  5. ./scripts/apply-cmek-to-state-bucket.sh $PROJECT_ID $REGION $STATE_BUCKET"
echo "============================================================"