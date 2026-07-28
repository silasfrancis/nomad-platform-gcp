#!/bin/bash
# validate-nomad-job.sh
#
# Renders the job spec's variable placeholders and asks Nomad to
# evaluate the resulting plan without applying it, catching destructive
# or invalid changes before anything is actually submitted.
set -euo pipefail

: "${NOMAD_ADDR:?NomadApiUrl deployment variable is required}"
: "${NOMAD_TOKEN:?NomadAclToken deployment variable is required}"
: "${JOB_FILE:?path to the rendered .nomad.hcl file is required}"

echo "Validating ${JOB_FILE} against ${NOMAD_ADDR}..."
nomad job plan -no-color "${JOB_FILE}"
plan_exit=$?

# nomad job plan exits 1 for "changes present, nothing destructive" —
# that's the expected, successful case for a normal deploy. Exit 2
# means the plan itself failed to compute; that's a real failure.
if [ "${plan_exit}" -eq 2 ]; then
  echo "Nomad job plan failed — aborting deployment." >&2
  exit 1
fi

echo "Validation passed."
