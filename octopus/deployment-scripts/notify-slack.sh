#!/bin/bash
# notify-slack.sh
#
# Posts a deployment outcome to Slack. Never fails the release on its
# own account — a Slack outage should not block a deployment that
# otherwise succeeded. Run with condition = "Always" so it fires
# whether earlier steps succeeded or failed.
set -uo pipefail

SlackWebhookUrl="$(get_octopusvariable "SlackWebhookUrl")"
: "${SlackWebhookUrl:?SlackWebhookUrl deployment variable is required}"

# Built-in Octopus system variables 
PROJECT_NAME="$(get_octopusvariable "Octopus.Project.Name")"
ENVIRONMENT_NAME="$(get_octopusvariable "Octopus.Environment.Name")"
RELEASE_NUMBER="$(get_octopusvariable "Octopus.Release.Number")"

# Octopus.Deployment.Error/.ErrorDetail are populated the moment any
# step in this deployment fails
# .Error is the short exit code/message; .ErrorDetail adds Octopus's
# own stack trace on top of it. 
DEPLOYMENT_ERROR="$(get_octopusvariable "Octopus.Deployment.Error")"
DEPLOYMENT_ERROR_DETAIL="$(get_octopusvariable "Octopus.Deployment.ErrorDetail")"

if [ -n "${DEPLOYMENT_ERROR}" ]; then
  OUTCOME="failed: ${DEPLOYMENT_ERROR}"
else
  OUTCOME="succeeded"
fi

TEXT="${PROJECT_NAME} ${RELEASE_NUMBER} ${OUTCOME} in ${ENVIRONMENT_NAME}"

# ErrorDetail is a raw stack trace and can contain quotes, 
# backslashes, and newlines that would otherwise produce
# invalid JSON or truncate the payload. --arg escapes all of that
# safely regardless of content. ErrorDetail is only added to the
# payload when non-empty, so a successful deployment's message stays
# a single short line.
if [ -n "${DEPLOYMENT_ERROR_DETAIL}" ]; then
  payload="$(jq -n --arg text "${TEXT}" --arg detail "${DEPLOYMENT_ERROR_DETAIL}" \
    '{text: ($text + "\n```" + $detail + "```")}')"
else
  payload="$(jq -n --arg text "${TEXT}" '{text: $text}')"
fi

curl -s -X POST -H 'Content-Type: application/json' -d "${payload}" "${SlackWebhookUrl}" \
  || echo "Slack notification failed to send — continuing, this step never blocks the release."

exit 0
