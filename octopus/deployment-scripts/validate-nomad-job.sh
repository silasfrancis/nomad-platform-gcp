#!/bin/bash
# validate-nomad-job.sh
#
# Renders the job spec and asks Nomad to evaluate the resulting plan
# without applying it, catching invalid or unexpectedly destructive
# changes before anything is actually submitted.
set -euo pipefail
source "$(dirname "$0")/common.sh"

# mapfile (not `while read < <(discover_job_files)`) so discover_job_files'
# own exit status is visible here — a process substitution runs in a
# subshell and would swallow a "no file found" failure silently.
mapfile -t job_files < <(discover_job_files)
if [ "${#job_files[@]}" -eq 0 ]; then
  fail_with_reason "No .nomad.hcl file found in package root."
fi

for job_file in "${job_files[@]}"; do
  job_id="$(job_id_from_file "${job_file}")"
  echo "Validating ${job_file} (job \"${job_id}\") against ${NOMAD_ADDR} (namespace ${NOMAD_NAMESPACE})..."

  set +e
  validate_output="$(nomad job validate -namespace "${NOMAD_NAMESPACE}" "${job_file}" 2>&1)"
  validate_exit=$?
  set -e
  echo "${validate_output}"

  if [ "${validate_exit}" -ne 0 ]; then
    fail_with_reason "Nomad job validate failed for ${job_id}: $(echo "${validate_output}" | tail -n 5)"
  fi

  # Output captured (not just streamed) so the real error text is
  # available for fail_with_reason below — the -no-color flag already
  # keeps it free of ANSI codes, so capturing doesn't lose anything a
  # human would see live.
  set +e
  plan_output="$(nomad job plan -namespace "${NOMAD_NAMESPACE}" -no-color "${job_file}" 2>&1)"
  plan_exit=$?
  set -e
  echo "${plan_output}"

  # Nomad's own documented exit codes for `job plan` (developer.hashicorp.com/nomad/commands/job/plan):
  #   0   = no allocations created or destroyed
  #   1   = allocations created or destroyed — expected, not a failure
  #   255 = error determining plan results — a real failure (auth
  #         errors, unreachable server, invalid job, etc.)
  # Anything else previously assumed here (an old check of `-eq 2`)
  # never matched a real error and let genuine plan failures — like a
  # 403 from an ACL/namespace mismatch — through as a false "passed".
  if [ "${plan_exit}" -eq 255 ]; then
    fail_with_reason "Nomad job plan failed for ${job_id}: $(echo "${plan_output}" | tail -n 5)"
  fi

  echo "Validation passed for ${job_id}."
done
