#!/bin/bash
# Prepare the backup working area and hand off to the scheduler.

set -Eeuo pipefail

log() { printf 'level=%s job=entrypoint event=%s %s\n' "$1" "$2" "${3:-}"; }
die() { log error "$1" "${2:-}"; exit 1; }

WORKSPACE="/workspace"
DEST="/backup"
DEST_GIT_DIR="${DEST}/workspace.git"

for tool in git rsync supercronic; do
  command -v "${tool}" >/dev/null 2>&1 || die missing_tool "${tool} is not installed"
done

[ -d "${WORKSPACE}" ] || die missing_workspace "${WORKSPACE} is not mounted"
[ -d "${WORKSPACE}/.git" ] \
  || die not_a_repo "${WORKSPACE} is not a git repository; run make init on the host"

touch "${GIT_CONFIG_GLOBAL}"
git config --global --replace-all safe.directory "${WORKSPACE}"
git config --global --replace-all safe.directory "${DEST_GIT_DIR}"
git config --global user.name  "ai-workspace-backup"
git config --global user.email "backup@localhost"

# Deliberately not fatal. A crash-looping container tells nobody anything.
# Coming up lets the jobs write WARNINGS.md into the workspace, which is the
# whole point of having it.
[ -f "${DEST}/.aiwr-backup" ] \
  || log warn dest_unverified "${DEST} has no marker; jobs will report this until it is mounted"

CRONTAB=/tmp/crontab
: > "${CRONTAB}"
add_job() {
  local spec="$1" script="$2"
  [ -n "${spec}" ] || return 0
  printf '%s /opt/aiwr/%s\n' "${spec}" "${script}" >> "${CRONTAB}"
  log info scheduled "script=${script} spec=${spec}"
}
# Only the commit interval is worth tuning. The rest is maintenance cadence.
add_job "${BACKUP_COMMIT_CRON:-7 * * * *}"    commit.sh
add_job "47 * * * *"                          transcripts.sh
add_job "30 4 * * 0"                          maintain.sh

log info start "uid=$(id -u) gid=$(id -g) dest=${DEST_GIT_DIR}"

# -passthrough-logs sends each job's own stdout/stderr straight through, so
# `docker logs` shows the structured lines the scripts emit rather than
# supercronic's re-wrapping of them.
exec supercronic -passthrough-logs "${CRONTAB}"
