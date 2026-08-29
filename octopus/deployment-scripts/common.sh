#!/bin/bash
# common.sh
#
# Sourced by every deployment script — not runnable on its own.
#
# Two jobs: bridge Octopus's project-scoped variables to the names
# these scripts use internally, and discover what's actually in the
# package rather than expecting Octopus to tell us. Project variables
# (DeploymentNamespace, PublicHostname, RemediationMode, ...) are
# scoped to the whole project — shared by every service Nomad-routed
# there since the 23-projects-to-5 consolidation — so there is no
# variable scope left that could hold one specific service's own job
# ID, protocol, or port. Those facts come from the package's own
# .nomad.hcl file(s) and from Nomad/Consul's live state instead, which
# also means they can never drift out of sync with what's actually
# deployed the way a hand-maintained variable could.

: "${NomadApiUrl:?NomadApiUrl is required}"
: "${NomadAclToken:?NomadAclToken is required}"
NOMAD_ADDR="${NomadApiUrl}"
NOMAD_TOKEN="${NomadAclToken}"
export NOMAD_ADDR NOMAD_TOKEN

# Discover every .nomad.hcl file in the package root. Usually one —
# each CI matrix item packages its own service's job spec — but this
# doesn't assume that; a package containing more than one job spec is
# looped over, not silently dropped to the first match.
discover_job_files() {
  local files=()
  while IFS= read -r -d '' f; do
    files+=("${f}")
  done < <(find . -maxdepth 1 -type f -name '*.nomad.hcl' -print0)

  if [ "${#files[@]}" -eq 0 ]; then
    echo "No .nomad.hcl file found in package." >&2
    exit 1
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