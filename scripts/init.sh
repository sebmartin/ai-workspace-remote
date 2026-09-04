#!/bin/bash
# Set up, or re-check, everything .env describes. Everything here is
# idempotent, so re-running it is how you ask "am I set up correctly?".
#
# It does the mechanical work and stops with a named problem when it cannot.
# Nothing in here is something the reader has to remember.

set -Eeuo pipefail

cd "$(dirname "$0")/.."
ENV_FILE=.env

ok()  { printf '  \033[32mok\033[0m    %s\n' "$1"; }
did() { printf '  \033[36mdid\033[0m   %s\n' "$1"; }
note(){ printf '  \033[33mnote\033[0m  %s\n' "$1"; }
die() { printf '\n\033[31m%s\033[0m\n' "$1" >&2; [ $# -gt 1 ] && printf '%s\n' "$2" >&2; exit 1; }

# Read a key without sourcing, so a stray line in .env cannot execute.
get() { sed -n "s/^$1=//p" "${ENV_FILE}" | tail -1 | sed 's/[[:space:]]*$//'; }

set_key() {
  if grep -q "^$1=" "${ENV_FILE}"; then
    sed -i.bak "s|^$1=.*|$1=$2|" "${ENV_FILE}" && rm -f "${ENV_FILE}.bak"
  else
    printf '%s=%s\n' "$1" "$2" >> "${ENV_FILE}"
  fi
}

if [ ! -f "${ENV_FILE}" ]; then
  cp .env.example "${ENV_FILE}"
  chmod 600 "${ENV_FILE}"
  did "created .env from .env.example"
fi

# Ask for the two values that have no sensible default. Every other key in
# .env ships with one, so nothing else is ever prompted for.
ask() {
  local key="$1" prompt="$2" suggest="${3:-}" value
  value="$(get "${key}")"
  [ -n "${value}" ] && { ok "${key}=${value}"; return 0; }

  # Never `read` without a terminal: it returns immediately at EOF and would
  # loop, or in other harnesses hang, instead of telling you what is missing.
  if [ ! -t 0 ]; then
    die "${key} is not set in .env." "${prompt}"
  fi

  printf '\n%s\n' "${prompt}"
  while [ -z "${value}" ]; do
    if [ -n "${suggest}" ]; then
      read -r -p "${key} [${suggest}]: " value || die "Cancelled."
      value="${value:-${suggest}}"
    else
      read -r -p "${key}: " value || die "Cancelled."
    fi
    case "${value}" in
      /?*) ;;
      *) printf '  must be an absolute path\n'; value="" ;;
    esac
  done
  set_key "${key}" "${value}"
  did "${key}=${value}"
}

echo "Checking .env"

ask AIWR_ROOT \
  "AIWR_ROOT is the one directory this stack owns. It will hold the workspace and Claude's home." \
  /srv/ai-workspace
ask BACKUP_MOUNT \
  "BACKUP_MOUNT is where the backup goes: a directory on storage you have already mounted. A NAS share, a second disk, a USB enclosure. Mount it first, because an unmounted path is an empty directory and the backup would fill this machine's disk instead."

AIWR_ROOT="$(get AIWR_ROOT)"
BACKUP_MOUNT="$(get BACKUP_MOUNT)"

for stale in NAS_HOST NAS_USER NAS_ROOT NAS_PORT; do
  [ -n "$(get "${stale}")" ] && note "${stale} is no longer used and is ignored. Delete it when you like."
done

# Whoever runs this owns the tree, so the containers can align to it without
# anyone typing a number.
UID_NOW="$(id -u)"; GID_NOW="$(id -g)"
if [ "$(get WORKSPACE_UID)" != "${UID_NOW}" ] || [ "$(get WORKSPACE_GID)" != "${GID_NOW}" ]; then
  set_key WORKSPACE_UID "${UID_NOW}"
  set_key WORKSPACE_GID "${GID_NOW}"
  did "recorded WORKSPACE_UID=${UID_NOW} WORKSPACE_GID=${GID_NOW}"
fi

echo
echo "Setting up ${AIWR_ROOT}"

# `chown -R` on a path someone just typed deserves one question first.
if [ -t 0 ] && [ -d "${AIWR_ROOT}" ] && [ -n "$(ls -A "${AIWR_ROOT}" 2>/dev/null)" ]; then
  if [ ! -d "${AIWR_ROOT}/workspace" ]; then
    printf '\n%s already exists and is not empty.\n' "${AIWR_ROOT}"
    printf 'This will chown everything under it to %s and set it 0700.\n' "${UID_NOW}"
    read -r -p "Continue? [y/N]: " reply || die "Cancelled."
    case "${reply}" in y|Y|yes) ;; *) die "Stopped. Set AIWR_ROOT to somewhere else." ;; esac
  fi
fi

sudo mkdir -p "${AIWR_ROOT}/workspace" "${AIWR_ROOT}/home/.claude"
sudo chown -R "${UID_NOW}:${GID_NOW}" "${AIWR_ROOT}"
sudo chmod 700 "${AIWR_ROOT}"
ok "workspace/ and home/, owned by ${UID_NOW}, root is 0700"

[ -d "${AIWR_ROOT}/backup" ] \
  && note "${AIWR_ROOT}/backup is left over from the old layout and is no longer used. It may still be your only backup, so check the new one before deleting it."

# Docker creates a directory here if the file is absent, and Claude then fails
# in a way that does not mention it.
if [ ! -s "${AIWR_ROOT}/home/.claude.json" ]; then
  printf '{}' > "${AIWR_ROOT}/home/.claude.json"
  chmod 600 "${AIWR_ROOT}/home/.claude.json"
  did "created home/.claude.json"
fi

if [ ! -d "${AIWR_ROOT}/workspace/.git" ]; then
  if [ -n "$(ls -A "${AIWR_ROOT}/workspace" 2>/dev/null)" ]; then
    die "${AIWR_ROOT}/workspace has files in it but is not a git repository." \
        "Either run 'git init' there yourself, or move those files aside and copy in a workspace that is already a repo."
  fi
  git init -q -b main "${AIWR_ROOT}/workspace"
  did "git init workspace/"
fi

# WARNINGS.md is a live status file the backup jobs write. Ignoring it keeps it
# out of the snapshot, which matters because it carries a timestamp: in the
# tree it would change the commit every hour and defeat the no-op idle tick.
GI="${AIWR_ROOT}/workspace/.gitignore"
for line in '.DS_Store' '._*' '.Spotlight-V100' '.Trashes' '/WARNINGS.md'; do
  grep -qxF "${line}" "${GI}" 2>/dev/null || { printf '%s\n' "${line}" >> "${GI}"; did "added ${line} to workspace/.gitignore"; }
done

echo
echo "Setting up secrets/"
mkdir -p secrets && chmod 700 secrets
if [ ! -s secrets/smb_password ]; then
  # pipefail off for this one line: head closes the pipe at 24 bytes, tr takes
  # SIGPIPE, and the pipeline would otherwise report failure for working right.
  ( umask 077; set +o pipefail
    LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24 > secrets/smb_password )
  did "generated the SMB password"
fi
ok "SMB user 'claude', password in secrets/smb_password"

echo
echo "Setting up ${BACKUP_MOUNT}"

# No sudo and no chown. It has to be writable by the uid running this, because
# that is the uid the container runs as, and creating the repo below is the
# check that it is.
mkdir -p "${BACKUP_MOUNT}" 2>/dev/null \
  || die "Cannot create ${BACKUP_MOUNT}." "Mount the storage there first, or check it is writable by $(id -un)."

if [ ! -d "${BACKUP_MOUNT}/workspace.git" ]; then
  git init --bare -q -b main "${BACKUP_MOUNT}/workspace.git" \
    || die "Cannot write to ${BACKUP_MOUNT}." \
           "It exists but is not writable by $(id -un). On a cifs mount, add uid=${UID_NOW},gid=${GID_NOW},file_mode=0600,dir_mode=0700 to its mount options."
  did "created ${BACKUP_MOUNT}/workspace.git"
fi

# Last, so it is only ever there once everything above worked. The jobs treat
# its absence as "the storage is not mounted" and refuse to write.
touch "${BACKUP_MOUNT}/.aiwr-backup"
ok "backup storage ready and marked"

echo
echo "Ready. Review .env if you want to change anything, then:"
echo "  make up"
echo "  make login"
