#!/bin/bash
# common.sh
#
# Sourced by every deployment script — not runnable on its own.

NomadApiUrl="$(get_octopusvariable "NomadApiUrl")"
NomadAclToken="$(get_octopusvariable "NomadAclToken")"

: "${NomadApiUrl:?NomadApiUrl is required}"
: "${NomadAclToken:?NomadAclToken is required}"

export NOMAD_ADDR="$NomadApiUrl"
export NOMAD_TOKEN="$NomadAclToken"

# Absolute path to the package root. Calamari runs each step's script
# from inside package_root/scripts (this script's own directory), but
# the .nomad.hcl file(s) ship one level up, at the package root
# alongside scripts
PACKAGE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

discover_job_files() {
  local files=()
  while IFS= read -r -d '' f; do
    files+=("${f}")
  done < <(find "${PACKAGE_ROOT}" -maxdepth 1 -type f -name '*.nomad.hcl' -print0)

  if [ "${#files[@]}" -eq 0 ]; then
    echo "No .nomad.hcl file found in package root (${PACKAGE_ROOT})." >&2
    return 1
  fi
  printf '%s\n' "${files[@]}"
}

# Pulls the job ID straight out of `job "<id>" {` in the file itself —
# this always matches Nomad's own understanding of the job, so it can
# never drift out of sync the way a separately-maintained variable
# could.
job_id_from_file() {
  local file="$1"
  local id
  id="$(sed -n 's/^job[[:space:]]*"\([^"]*\)".*/\1/p' "${file}" | head -n1)"
  if [ -z "${id}" ]; then
    echo "Could not extract job ID from ${file}" >&2
    exit 1
  fi
  printf '%s' "${id}"
}

# True if this job's spec was configured for canary deploys (any task
# group's update.canary > 0) — checked against the JOB SPEC itself,
# not deployment runtime state, so it reflects what was actually
# declared regardless of what stage the deployment is currently in.
job_has_canary() {
  local job_id="$1"
  local canary_count
  canary_count="$(nomad job inspect -json "${job_id}" | jq -r '[.Job.TaskGroups[].Update.Canary // 0] | max')"
  [ "${canary_count}" -gt 0 ]
}

# True if any task group with canary > 0 also has auto_promote = true
# — meaning Nomad promotes it on its own once healthy, with no manual
# `nomad deployment promote` needed or accepted. Checked separately
# from job_has_canary since a job can have canary > 0 with either
# value here; conflating the two would either skip a job that
# genuinely needs manual promotion, or call promote on one Nomad
# already handled itself (which errors, since it's not awaiting one).

job_auto_promotes() {
  local job_id="$1"
  local auto_promote
  auto_promote="$(nomad job inspect -json "${job_id}" \
    | jq -r '[.Job.TaskGroups[] | select((.Update.Canary // 0) > 0) | (.Update.AutoPromote // false)] | any')"
  [ "${auto_promote}" = "true" ]
}
