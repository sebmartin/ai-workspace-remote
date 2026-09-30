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

JOB="${JOB:-unknown}"

# One file per fault, named for the job that raised it. A directory rather than
# one sectioned file because several tools write faults into this workspace and
# a shared file means every one of them needs the same parser, in whatever
# language it happens to be written in. Whole-file writes have no parser and no
# read-modify-write, so two writers cannot drop each other's faults.
#
# `.transient.md` says this fault is about a running container rather than about
# the files, so it must not survive into history. One gitignore pattern covers
# every writer that wants it, and a writer that wants its faults kept simply
# does not use the suffix. Readers glob `*.md` and see both.
WARNINGS="${WORKSPACE}/WARNINGS"
WARNING_FILE="${WARNINGS}/backup-${JOB}.transient.md"

log()  { printf 'level=%s job=%s event=%s %s\n' "$1" "${JOB}" "$2" "${3:-}"; }
info() { log info "$1" "${2:-}"; }
warn() { log warn "$1" "${2:-}"; }

git_ws()   { git -C "${WORKSPACE}" "$@"; }
git_dest() { git --git-dir="${DEST_GIT_DIR}" "$@"; }

# The heading carries the job, so a reader concatenating the directory can tell
# three jobs failing on one root cause from one job failing. A writer cannot
# forget to identify itself, because it never writes the heading itself.
warn_raise() {
  local msg="$1" detail="$2" fix="${3:-}"
  mkdir -p "${WARNINGS}"
  {
    printf '# backup-%s: %s\n\n%s\n' "${JOB}" "${msg}" "${detail}"
    if [ -n "${fix}" ]; then printf '\nFix: `%s`\n' "${fix}"; fi
  } > "${WARNING_FILE}.tmp.$$" && mv "${WARNING_FILE}.tmp.$$" "${WARNING_FILE}"
}

warn_clear() { rm -f "${WARNING_FILE}"; }

# `trap - ERR` first, so a failure inside the handler cannot re-enter it.
trap 'rc=$?; trap - ERR; if [ $rc -ne 0 ]; then
  log error failed "rc=${rc}"
  warn_raise "the job did not complete" \
    "It exited ${rc}." \
    "docker compose logs backup"
fi; exit $rc' ERR

require_dest() {
  [ -f "${MARKER}" ] && return 0
  log error dest_missing "no ${MARKER}"
  warn_raise "the backup storage is not mounted" \
    "\`${MARKER}\` is missing, so ${DEST} is an empty directory rather than your backup storage. Nothing is being backed up. Writing anyway would fill the Docker host's own disk." \
    "mount it on the Docker host, then run: make init"
  exit 1
}
