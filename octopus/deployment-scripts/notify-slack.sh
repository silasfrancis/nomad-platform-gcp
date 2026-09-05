#!/bin/bash
# notify-slack.sh
#
# Posts a deployment outcome to Slack. Never fails the release on its
# own account — a Slack outage should not block a deployment that
# otherwise succeeded. Run with condition = "Always" so it fires
# whether earlier steps succeeded or failed.
set -uo pipefail

# Read via get_octopusvariable (same as NomadApiUrl in common.sh) rather
# than as a plain env var — the reliable way to pull a variable-set
# value regardless of Octopus's own env-var auto-export behavior.
SlackWebhookUrl="$(get_octopusvariable "SlackWebhookUrl")"
: "${SlackWebhookUrl:?SlackWebhookUrl deployment variable is required}"

# Built-in Octopus system variables — always present, no scoping to
# worry about.
PROJECT_NAME="$(get_octopusvariable "Octopus.Project.Name")"
ENVIRONMENT_NAME="$(get_octopusvariable "Octopus.Environment.Name")"
RELEASE_NUMBER="$(get_octopusvariable "Octopus.Release.Number")"
DEPLOYMENT_STEPS=(
  "validate-nomad-job"
  "deploy-to-nomad"
  "wait-for-healthy"
  "promote-deployment"
)

# Octopus.Deployment.Error is populated the moment ANY step in this
# deployment fails — not just one named step — so this doesn't need
# updating every time a step is added to or removed from the process.
DEPLOYMENT_ERROR="$(get_octopusvariable "Octopus.Deployment.Error")"

if [ -n "${DEPLOYMENT_ERROR}" ]; then
  OUTCOME="failed: ${DEPLOYMENT_ERROR}"
else
  OUTCOME="succeeded"
fi

TEXT="${PROJECT_NAME} ${RELEASE_NUMBER} ${OUTCOME} in ${ENVIRONMENT_NAME}"

# Octopus.Deployment.ErrorDetail is Octopus's OWN internal exception
# trace (ActivityFailedException / ActionFailedException / etc.) —
# never the actual script output, and Octopus's own docs say as much:
# "Octopus can't parse the deployment log, so it can only extract exit
# and error codes, not detailed information on the cause of the
# failure." So instead of that, check every step that COULD have set
# its own NomadFailureDetail output variable (each of common.sh's
# fail_with_reason calls, or a direct set_octopusvariable in
# promote-deployment.sh/wait-for-healthy.sh) — whichever step actually
# failed is the one whose variable comes back non-empty. Order matches
# the deployment process; the first non-empty result wins (only one
# step's variable will actually be set, since Octopus only reaches
# these steps in order and typically stops at the first failure).
DETAIL=""
for step in "${DEPLOYMENT_STEPS[@]}"; do
  step_detail="$(get_octopusvariable "Octopus.Action[${step}].Output.NomadFailureDetail")"
  if [ -n "${step_detail}" ]; then
    DETAIL="${step_detail}"
    break
  fi
done

# Fall back to Octopus's own ErrorDetail only if no step reported its
# own — covers failures outside these scripts entirely (e.g. Octopus
# itself failing to acquire/extract the package), where there's no
# NomadFailureDetail to have been set in the first place.
if [ -z "${DETAIL}" ]; then
  DETAIL="$(get_octopusvariable "Octopus.Deployment.ErrorDetail")"
fi

# Built with jq rather than a hand-rolled heredoc: DETAIL can contain
# quotes, backslashes, and newlines (raw Nomad output, stack traces)
# that would otherwise produce invalid JSON or truncate the payload.
# --arg escapes all of that safely regardless of content. DETAIL is
# only added to the payload when non-empty, so a successful
# deployment's message stays a single short line.
if [ -n "${DETAIL}" ]; then
  payload="$(jq -n --arg text "${TEXT}" --arg detail "${DETAIL}" \
    '{text: ($text + "\n```" + $detail + "```")}')"
else
  payload="$(jq -n --arg text "${TEXT}" '{text: $text}')"
fi

curl -s -X POST -H 'Content-Type: application/json' -d "${payload}" "${SlackWebhookUrl}" \
  || echo "Slack notification failed to send — continuing, this step never blocks the release."

exit 0
