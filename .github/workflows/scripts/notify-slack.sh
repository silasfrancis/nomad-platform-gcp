#!/bin/bash
# notify-slack.sh
#
# Posts a deployment outcome to Slack. Never fails the release on its
# own account — a Slack outage should not block a deployment that
# otherwise succeeded.
set -uo pipefail

: "${SlackWebhookUrl:?SlackWebhookUrl deployment variable is required}"
PROJECT_NAME="${OCTOPUS_PROJECT_NAME:-unknown project}"
ENVIRONMENT_NAME="${OCTOPUS_ENVIRONMENT_NAME:-unknown environment}"
RELEASE_NUMBER="${OCTOPUS_RELEASE_NUMBER:-unknown release}"
OUTCOME="${DEPLOYMENT_OUTCOME:-completed}"

payload=$(cat <<EOF
{"text": "${PROJECT_NAME} ${RELEASE_NUMBER} ${OUTCOME} in ${ENVIRONMENT_NAME}"}
EOF
)

curl -s -X POST -H 'Content-Type: application/json' -d "${payload}" "${SlackWebhookUrl}" \
  || echo "Slack notification failed to send — continuing, this step never blocks the release."

exit 0
