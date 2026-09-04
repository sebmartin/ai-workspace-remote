#!/bin/bash
# Shared helpers for the backup jobs. Sourced, never executed.

set -Eeuo pipefail

WORKSPACE="/workspace"
DEST="/backup"
DEST_GIT_DIR="${DEST}/workspace.git"

# Written by `make init` once the storage is mounted. An unmounted bind source
# is an empty directory, and Docker creates one if it is missing, so without
# this check git and rsync would write to the Docker host's own disk and report
# success. This file is the only thing that tells the two apart.
MARKER="${DEST}/.aiwr-backup"

# The only place a failure is recorded. An unhealthy container tells nobody;
# a file in the workspace is seen by whoever is working there.
WARNINGS="${WORKSPACE}/WARNINGS.md"

JOB="${JOB:-unknown}"

log()  { printf 'level=%s job=%s event=%s %s\n' "$1" "${JOB}" "$2" "${3:-}"; }
info() { log info "$1" "${2:-}"; }
warn() { log warn "$1" "${2:-}"; }

git_ws()   { git -C "${WORKSPACE}" "$@"; }
git_dest() { git --git-dir="${DEST_GIT_DIR}" "$@"; }

_warn_header() {
  printf '# Backup warnings\n\n'
  printf 'Written by ai-workspace-remote. It deletes this file once everything works.\n\n'
}

# Everything except this job's section. Each job owns one delimited block, so
# it can rewrite or remove its own without touching another's.
_warn_body() {
  [ -f "${WARNINGS}" ] || return 0
  sed "/^<!-- job:${JOB} -->\$/,/^<!-- \/job:${JOB} -->\$/d" "${WARNINGS}" \
    | sed -n '/^<!-- job:/,$p'
}

warn_set() {
  local msg="$1" detail="$2" fix="${3:-}" body tmp
  body="$(_warn_body)"
  tmp="${WARNINGS}.tmp.$$"
  {
    _warn_header
    # printf '%s\n', not '%s': command substitution strips the trailing
    # newline, which would run the previous section's closing marker into
    # this one's opening marker on the same line.
    if [ -n "${body}" ]; then printf '%s\n' "${body}"; fi
    printf '<!-- job:%s -->\n## %s\n\n%s\n' "${JOB}" "${msg}" "${detail}"
    if [ -n "${fix}" ]; then printf '\nFix: `%s`\n' "${fix}"; fi
    printf '\n<!-- /job:%s -->\n' "${JOB}"
  } > "${tmp}" && mv "${tmp}" "${WARNINGS}"
}

warn_clear() {
  [ -f "${WARNINGS}" ] || return 0
  local body tmp
  body="$(_warn_body)"
  if [ -z "${body}" ]; then rm -f "${WARNINGS}"; return 0; fi
  tmp="${WARNINGS}.tmp.$$"
  { _warn_header; printf '%s\n' "${body}"; } > "${tmp}" && mv "${tmp}" "${WARNINGS}"
}

# `trap - ERR` first, so a failure inside the handler cannot re-enter it.
trap 'rc=$?; trap - ERR; if [ $rc -ne 0 ]; then
  log error failed "rc=${rc}"
  warn_set "The ${JOB} job failed" \
    "It exited ${rc}. The last run did not complete." \
    "docker compose logs backup"
fi; exit $rc' ERR

require_dest() {
  [ -f "${MARKER}" ] && return 0
  log error dest_missing "no ${MARKER}"
  warn_set "The backup storage is not mounted" \
    "\`${MARKER}\` is missing, so ${DEST} is an empty directory rather than your backup storage. Nothing is being backed up. Writing anyway would fill the Docker host's own disk." \
    "mount it on the Docker host, then run: make init"
  exit 1
}
