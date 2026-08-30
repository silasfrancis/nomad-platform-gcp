#!/bin/bash
set -e


echo "============================================================"
echo "WARNING"
echo "============================================================"
echo "Ensure you are running this script from the"
echo "directory containing this Dockerfile."
echo ""
echo "Example:"
echo ">>> cd /octopus/worker"
echo ">>> ./build-push.sh"
echo "============================================================"
echo ""


IMAGE="octopus-worker"
REGION="${1:-europe-west1}"
PROJECT_ID="${2:-nomad-platform-gcp}"
REPOSITORY="${3:-nomad-platform-gcp}"

IMAGE_PATH="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPOSITORY}/${IMAGE}"

echo "Fetching existing tags from ${IMAGE_PATH}..."

# Fetch tags, filter for semver, sort, and get the latest
LATEST_TAG=$(gcloud artifacts docker tags list "${IMAGE_PATH}" --format="value(TAG)" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -n 1)

if [ -z "${LATEST_TAG}" ]; then
    NEW_TAG="0.0.1"
    echo "No existing semantic tags found. Starting fresh at: ${NEW_TAG}"
else
    echo "Latest existing tag found: ${LATEST_TAG}"
    
    # Parse major, minor, and patch
    IFS='.' read -r MAJOR MINOR PATCH <<< "${LATEST_TAG}"
    
    # Increment patch version
    PATCH=$((PATCH + 1))
    NEW_TAG="${MAJOR}.${MINOR}.${PATCH}"
    
    echo "Incremented tag to: ${NEW_TAG}"
fi

FULL_IMAGE_PATH="${IMAGE_PATH}:${NEW_TAG}"

echo "Building and pushing ${FULL_IMAGE_PATH}"
gcloud builds submit --tag "${FULL_IMAGE_PATH}" .

echo "Successfully built and pushed: ${FULL_IMAGE_PATH}"