#!/bin/bash
# Prepare the backup working area and hand off to the scheduler.

set -Eeuo pipefail

log() { printf 'level=%s job=entrypoint event=%s %s\n' "$1" "$2" "${3:-}"; }
die() { log error "$1" "${2:-}"; exit 1; }

WORKSPACE="/workspace"
BACKUP_GIT_DIR="/backup/workspace.git"
STATE_DIR="/backup/state"

# There is no passwd entry for a numeric `user:`, so nothing can be inferred.
export HOME=/tmp
export GIT_CONFIG_GLOBAL=/backup/gitconfig

for tool in git rsync ssh flock timeout supercronic; do
  command -v "${tool}" >/dev/null 2>&1 || die missing_tool "${tool} is not installed"
done

[ -d "${WORKSPACE}" ] || die missing_workspace "${WORKSPACE} is not mounted"
[ -d /backup ] || die missing_state "/backup is not mounted"

mkdir -p "${STATE_DIR}"
date +%s > "${STATE_DIR}/boot_at"

touch "${GIT_CONFIG_GLOBAL}"
git config --global --replace-all safe.directory "${WORKSPACE}"
git config --global --replace-all safe.directory "${BACKUP_GIT_DIR}"
git config --global user.name  "ai-workspace-backup"
git config --global user.email "backup@localhost"

# A read-only bind mount keeps the key's host ownership, and OpenSSH refuses
# a key it does not own or that others can read. Copying into tmpfs at 0600
# avoids having to chown anything on the host.
if [ -f /run/aiwr/id ]; then
  install -m 0600 /run/aiwr/id /tmp/id
else
  die missing_key "/run/aiwr/id is not mounted; NAS_SSH_KEY_HOST_PATH"
fi
[ -s /run/aiwr/known_hosts ] || die empty_known_hosts \
  "/run/aiwr/known_hosts is empty; run: ssh-keyscan -p ${NAS_PORT:-22} ${NAS_HOST:-<nas>} > secrets/known_hosts"

if [ ! -d "${BACKUP_GIT_DIR}" ]; then
  log info init_bare "path=${BACKUP_GIT_DIR}"
  git init --bare -q "${BACKUP_GIT_DIR}"
fi

if [ ! -d "${WORKSPACE}/.git" ]; then
  die not_a_repo "${WORKSPACE} is not a git repository; run 'git init' there first"
fi

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
add_job "17 * * * *"                          mirror.sh
add_job "47 * * * *"                          transcripts.sh
add_job "30 4 * * 0"                          maintain.sh

log info start "uid=$(id -u) gid=$(id -g) git_dir=${BACKUP_GIT_DIR}"

# -passthrough-logs sends each job's own stdout/stderr straight through, so
# `docker logs` shows the structured lines the scripts emit rather than
# supercronic's re-wrapping of them.
exec supercronic -passthrough-logs "${CRONTAB}"
