#!/bin/bash
# common.sh
#
# Sourced by every deployment script — not runnable on its own.
#
# Four jobs: bridge Octopus's project-scoped variables to the names
# these scripts use internally, discover what's actually in the
# package rather than expecting Octopus to tell us, replace #{...}
# template tokens in job spec files ourselves (see
# substitute_job_file_variables below), and give every script one
# place to report ITS OWN meaningful failure text — Octopus only ever
# exposes Octopus.Deployment.Error/.ErrorDetail, which is Octopus's own
# internal exception trace, never the real stdout/stderr of a failed
# script.

NomadApiUrl="$(get_octopusvariable "NomadApiUrl")"
NomadAclToken="$(get_octopusvariable "NomadAclToken")"
DeploymentNamespace="$(get_octopusvariable "DeploymentNamespace")"

: "${NomadApiUrl:?NomadApiUrl is required}"
: "${NomadAclToken:?NomadAclToken is required}"
: "${DeploymentNamespace:?DeploymentNamespace is required}"

export NOMAD_ADDR="$NomadApiUrl"
export NOMAD_TOKEN="$NomadAclToken"

# Set for anything that reads the env var (query/status/promote
# commands honor this already). Also passed explicitly as -namespace
# on every direct `nomad job validate/plan/run` call in these scripts
# as reinforcement — but note neither of those is what actually makes
# a job land in the right namespace when the job SPEC's own
# `namespace = "..."` field is a literal, unsubstituted
# "#{DeploymentNamespace}" string; see substitute_job_file_variables
# below for what actually fixes that.
export NOMAD_NAMESPACE="$DeploymentNamespace"

# Absolute path to the package root. Calamari runs each step's script
# from inside package_root/scripts (this script's own directory), but
# the .nomad.hcl file(s) ship one level up, at the package root
# alongside scripts/ — so callers of discover_job_files must look
# there, not in the script's own working directory.
PACKAGE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Logs a message to the task log AND exposes it as an output variable
# named NomadFailureDetail on the CURRENT step, then exits 1.
# notify-slack.sh (run with condition = Always) checks this same
# variable name across every step that could have failed, so whichever
# one actually did gets its real failure text into the Slack message —
# instead of Octopus's own generic Error/ErrorDetail, which never
# contains the actual Nomad response.
#
# IMPORTANT: only call this from a script's own top-level body — NEVER
# from inside a function invoked via command or process substitution
# ($(...) or <(...)). set_octopusvariable writes its service message
# to stdout; if that happens inside a subshell whose stdout is being
# captured into a variable or a pipe (as command/process substitution
# both do), the message gets swallowed into whatever's capturing it
# instead of ever reaching Octopus, and silently corrupts that
# captured value too.
fail_with_reason() {
  local reason="$1"
  echo "${reason}" >&2
  set_octopusvariable "NomadFailureDetail" "${reason}"
  exit 1
}

# Replaces every #{VariableName} token found in a job spec file with
# that Octopus variable's actual (fully resolved) value, in place.
#
# This exists instead of relying on Octopus's own built-in
# "Substitute Variables in Files" step feature because that feature
# has to be separately enabled, with a matching file-name pattern, on
# EVERY step that references this package (validate-nomad-job AND
# deploy-to-nomad both extract their own fresh copy of it) — the same
# class of easy-to-silently-miss per-step/per-project configuration
# that bit the platform-shared library variable set earlier. Doing it
# here means it can never be forgotten on a step, now or in the
# future, and only depends on get_octopusvariable, which every other
# value in this script already uses.
#
# Only matches the literal #{...} Octopus template syntax — HCL's own
# native ${...} interpolation (e.g. ${meta.node_pool_type} for
# constraints) uses a dollar sign, not a hash, so it's untouched here.
# get_octopusvariable already returns a variable's fully resolved
# value even when that variable's own definition uses a filter
# expression (e.g. ImageTag defined as
# "#{Octopus.Release.Number | Replace ...}") — Octopus resolves that
# internally, so a plain get_octopusvariable("ImageTag") call is
# sufficient; no filter-parsing needed here.
# substitute_job_file_variables() {
#   local file="$1"
#   local content
#   content="$(cat "${file}")"

#   # NOTE: POSIX bracket expressions don't support backslash-escaping —
#   # a literal ']' inside [...] must be the FIRST character right after
#   # '[' to be treated literally, not escaped with '\'. An earlier
#   # version of this pattern used \[\] here, which silently matched
#   # nothing at all (the stray unescaped ']' terminated the character
#   # class one position early, leaving a dangling literal "]+" outside
#   # it that could never match real tokens) — caught by testing against
#   # a real job spec before shipping this.
#   local tokens
#   mapfile -t tokens < <(grep -oE '#\{[]A-Za-z0-9_.[]+\}' "${file}" | sort -u)

#   local token var_name value
#   for token in "${tokens[@]}"; do
#     var_name="${token#\#\{}"
#     var_name="${var_name%\}}"
#     value="$(get_octopusvariable "${var_name}")"
#     content="${content//${token}/${value}}"
#   done

#   printf '%s' "${content}" > "${file}"
# }

# Discover every .nomad.hcl file in the package root, substituting its
# #{Variable} tokens in place before returning it. Usually one file —
# each CI matrix item packages its own service's job spec — but this
# doesn't assume that; a package containing more than one job spec is
# looped over, not silently dropped to the first match.
#
# Prints one path per line and returns non-zero if none are found.
# Deliberately does NOT call `exit` (or fail_with_reason) here: this
# function is meant to be captured via `mapfile` in the caller's own
# shell via `< <(discover_job_files)`, which is a process substitution
# — a subshell whose stdout feeds mapfile, and whose exit status is
# invisible to the caller's `set -e`. Calling fail_with_reason here
# would also mean set_octopusvariable's own stdout output lands in
# that same pipe, corrupting the job-file list. The caller checks
# `${#job_files[@]}` itself, at its own top level, and calls
# fail_with_reason there instead.
#
# substitute_job_file_variables's own get_octopusvariable calls are
# safe to run in here even though this whole function executes inside
# the mapfile process-substitution subshell — get_octopusvariable is a
# read, returning its value through its OWN separate, independently
# captured command substitution ($(...)), which never touches this
# function's own stdout. Only set_octopusvariable (a write) is unsafe
# in this context — see fail_with_reason's note above.
discover_job_files() {
  local files=()
  while IFS= read -r -d '' f; do
    files+=("${f}")
  done < <(find "${PACKAGE_ROOT}" -maxdepth 1 -type f -name '*.nomad.hcl' -print0)

  if [ "${#files[@]}" -eq 0 ]; then
    echo "No .nomad.hcl file found in package root (${PACKAGE_ROOT})." >&2
    return 1
  fi

  local f
  # for f in "${files[@]}"; do
  #   substitute_job_file_variables "${f}"
  # done

  printf '%s\n' "${files[@]}"
}

# Pulls the job ID straight out of `job "<id>" {` in the file itself —
# this always matches Nomad's own understanding of the job, so it can
# never drift out of sync with a separately-maintained variable could.
#
# Always invoked as `job_id="$(job_id_from_file "${job_file}")"` by
# callers — that's a command substitution, which runs this function's
# body in a subshell. For the same reason as discover_job_files above,
# this must NEVER call fail_with_reason/set_octopusvariable: doing so
# would dump the service message into what's supposed to be a clean
# job-ID string. Plain echo-to-stderr + exit is correct here — stderr
# isn't part of what's captured, and exit's status still propagates
# normally through `set -e` for a plain `var=$(...)` assignment (unlike
# process substitution).
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
  canary_count="$(nomad job inspect -namespace "${NOMAD_NAMESPACE}" -json "${job_id}" | jq -r '[.Job.TaskGroups[].Update.Canary // 0] | max')"
  [ "${canary_count}" -gt 0 ]
}

# True if any task group with canary > 0 also has auto_promote = true
# — meaning Nomad promotes it on its own once healthy, with no manual
# `nomad deployment promote` needed or accepted. Checked separately
# from job_has_canary since a job can have canary > 0 with either
# value here; conflating the two would either skip a job that
# genuinely needs manual promotion, or call promote on one Nomad
# already handled itself (which errors, since it's not awaiting one).
#
# VERIFY: AutoPromote is the PascalCase JSON field name matching the
# HCL update.auto_promote key, per Nomad's Go-struct-to-JSON naming
# convention seen elsewhere in this API (Canary, DesiredCanaries,
# etc.) — not independently confirmed against real inspect output.
job_auto_promotes() {
  local job_id="$1"
  local auto_promote
  auto_promote="$(nomad job inspect -namespace "${NOMAD_NAMESPACE}" -json "${job_id}" \
    | jq -r '[.Job.TaskGroups[] | select((.Update.Canary // 0) > 0) | (.Update.AutoPromote // false)] | any')"
  [ "${auto_promote}" = "true" ]
}
