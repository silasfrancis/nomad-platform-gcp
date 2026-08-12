#!/bin/bash
# scripts/apply-cmek-to-state-bucket.sh
#
# Applies CMEK encryption to the Terraform state bucket using the
# gcs-storage key created by terraform/bootstrap.
#
# Must run AFTER terraform/bootstrap apply — the KMS key does not exist
# until bootstrap creates it. This is the only reason this is a separate
# script rather than part of bootstrap-prereqs.sh.
#
# Existing state objects are NOT retroactively re-encrypted — they will be
# re-encrypted on next write (next terraform apply or state operation).
# New objects written after this point are encrypted with your CMEK key.
#
# Usage:
#   ./scripts/apply-cmek-to-state-bucket.sh <project_id> <state_bucket_name>
#
# Example:
#   ./scripts/apply-cmek-to-state-bucket.sh nomad-platform-gcp europe-west1 tfstate

set -euo pipefail

PROJECT_ID="${1:-}"
REGION="${2:-europe-west1}"
STATE_BUCKET="${3:-}"

if [[ -z "$PROJECT_ID" || -z "$STATE_BUCKET" ]]; then
  echo "Usage: $0 <project_id> [region] <state_bucket_name>"
  exit 1
fi

echo "==> Project:      $PROJECT_ID"
echo "==> Region:       $REGION"
echo "==> State bucket: gs://$PROJECT_ID-$REGION-$STATE_BUCKET"
echo ""

echo "==> Reading gcs-storage key ID from Terraform bootstrap outputs"
cd terraform/bootstrap

KEY_ID=$(terraform output -json kms_keys | jq -r '."platform/storage-cmek".id' 2>/dev/null || echo "")

if [[ -z "$KEY_ID" ]]; then
  echo "ERROR: storage_cmek_id output is empty."
  echo "       Run: cd terraform/bootstrap && terraform apply"
  exit 1
fi

echo "==> Applying CMEK to gs://$PROJECT_ID-$REGION-$STATE_BUCKET"
echo "    Key: $KEY_ID"

gcloud storage buckets update "gs://$PROJECT_ID-$REGION-$STATE_BUCKET" \
  --default-encryption-key="$KEY_ID"

echo ""
echo "============================================================"
echo "CMEK applied to gs://$PROJECT_ID-$REGION-$STATE_BUCKET"
echo ""
echo "Note: Existing state objects are encrypted with Google-managed"
echo "keys until next write. Run terraform apply in any layer to"
echo "trigger a state write and re-encrypt with your CMEK key."
echo "============================================================"