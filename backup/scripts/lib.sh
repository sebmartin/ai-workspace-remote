#!/bin/bash
# Shared helpers for the backup jobs. Sourced, never executed.

set -Eeuo pipefail

STATE_DIR="/backup/state"
GIT_LOCK="${STATE_DIR}/git.lock"
TRANSCRIPTS_LOCK="${STATE_DIR}/transcripts.lock"
CORRUPT_MARKER="${STATE_DIR}/corrupt"

WORKSPACE="/workspace"
BACKUP_GIT_DIR="/backup/workspace.git"
LOCK_WAIT=300

JOB="${JOB:-unknown}"

log()  { printf 'level=%s job=%s event=%s %s\n' "$1" "${JOB}" "$2" "${3:-}"; }
info() { log info "$1" "${2:-}"; }
warn() { log warn "$1" "${2:-}"; }

# Any unhandled failure records a failure and exits non-zero, so supercronic
# prints it with the job name and the healthcheck notices. Nothing reports
# success unless it reached record_success on the happy path.
trap 'rc=$?; if [ $rc -ne 0 ]; then log error failed "rc=${rc} line=${LINENO}"; record_failure "$rc"; fi; exit $rc' ERR

record_success() {
  mkdir -p "${STATE_DIR}"
  date +%s > "${STATE_DIR}/last_success_${JOB}"
  rm -f "${STATE_DIR}/failed_${JOB}"
}

record_failure() {
  mkdir -p "${STATE_DIR}"
  printf 'rc=%s at=%s\n' "${1:-1}" "$(date -Is)" > "${STATE_DIR}/failed_${JOB}"
}

# One lock for the three git jobs, so a gc can never run during a mirror and
# a long mirror can never race a commit.
#
# This only takes the lock. It deliberately does not run the job for you: a
# function invoked in a condition context has errexit disabled for its whole
# call tree, so wrapping the job that way would silently let it continue past
# a failed command and reach record_success. Callers do `take_lock || ...`
# and then call the job bare.
take_lock() {
  mkdir -p "${STATE_DIR}"
  exec 9>"$1"
  flock -w "${LOCK_WAIT}" 9
}

ssh_cmd() {
  printf '%s' "ssh -i /tmp/id -p ${NAS_PORT:-22} \
-o IdentitiesOnly=yes \
-o BatchMode=yes \
-o StrictHostKeyChecking=yes \
-o UserKnownHostsFile=/run/aiwr/known_hosts \
-o ConnectTimeout=10"
}

git_ws() { git -C "${WORKSPACE}" "$@"; }
git_bare() { git --git-dir="${BACKUP_GIT_DIR}" "$@"; }
