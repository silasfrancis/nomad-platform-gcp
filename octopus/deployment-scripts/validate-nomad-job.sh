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
  exit 1
fi

for job_file in "${job_files[@]}"; do
  job_id="$(job_id_from_file "${job_file}")"
  echo "Validating ${job_file} (job \"${job_id}\") against ${NOMAD_ADDR}..."

  nomad job validate "${job_file}"

  set +e
  nomad job plan -no-color "${job_file}"
  plan_exit=$?
  set -e

  # Nomad's own documented exit codes for `job plan`:
  #   0   = no allocations created or destroyed
  #   1   = allocations created or destroyed — expected, not a failure
  #   255 = error determining plan results — a real failure (auth
  #         errors, unreachable server, invalid job, etc.)
  if [ "${plan_exit}" -eq 255 ]; then
    echo "Nomad job plan failed for ${job_id} — aborting deployment." >&2
    exit 1
  fi

  echo "Validation passed for ${job_id}."
done
