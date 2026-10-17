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

# A trailing slash renders as /a//b everywhere the value is used, and rsync
# treats one as significant, so normalise it away at the single point where
# values enter.
trim_slashes() {
  local v="$1"
  while [ "${v}" != "${v%/}" ]; do v="${v%/}"; done
  printf '%s' "${v}"
}

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
      /?*) value="$(trim_slashes "${value}")" ;;
      *) printf '  must be an absolute path\n'; value="" ;;
    esac
    [ -z "${value}" ] && printf '  must be an absolute path\n'
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

# Also normalise values that were already in .env, whether hand-edited or
# written before this ran.
for key in AIWR_ROOT BACKUP_MOUNT; do
  raw="$(get "${key}")"
  trimmed="$(trim_slashes "${raw}")"
  [ -z "${trimmed}" ] && die "${key} is set to ${raw}, which is not a usable path."
  [ "${trimmed}" != "${raw}" ] && { set_key "${key}" "${trimmed}"; did "${key}=${trimmed}, trailing slash removed"; }
done

AIWR_ROOT="$(get AIWR_ROOT)"
BACKUP_MOUNT="$(get BACKUP_MOUNT)"

# Empty means src/ under AIWR_ROOT, which is what compose falls back to.
SRC_MOUNT="$(trim_slashes "$(get SRC_MOUNT)")"
[ -n "${SRC_MOUNT}" ] && set_key SRC_MOUNT "${SRC_MOUNT}"
SRC_DIR="${SRC_MOUNT:-${AIWR_ROOT}/src}"

if [ -n "${SRC_MOUNT}" ]; then
  ok "SRC_MOUNT=${SRC_MOUNT}"
else
  ok "SRC_MOUNT is unset, so /src is ${SRC_DIR}"
fi

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

# Whoever runs this is who the agent commits as, so take the identity from
# their git config rather than asking for it again. Only when unset: a value
# in .env is deliberate.
for pair in "GIT_USER_NAME:user.name" "GIT_USER_EMAIL:user.email"; do
  key="${pair%%:*}"; gitkey="${pair#*:}"
  if [ -z "$(get "${key}")" ]; then
    val="$(git config --get "${gitkey}" 2>/dev/null || true)"
    if [ -n "${val}" ]; then
      set_key "${key}" "${val}"
      did "${key}=${val}, from this host's git config"
    else
      note "${key} is unset and this host has no ${gitkey}." \
           "Set it in .env, or a commit under /src will fail."
    fi
  else
    ok "${key}=$(get "${key}")"
  fi
done

echo
echo "Setting up ${AIWR_ROOT}"

# `chown -R` on a path someone just typed deserves one question first.
if [ -t 0 ] && [ -d "${AIWR_ROOT}" ] && [ -n "$(ls -A "${AIWR_ROOT}" 2>/dev/null)" ]; then
  if [ ! -d "${AIWR_ROOT}/workspace" ]; then
    printf '\n%s already exists and is not empty.\n' "${AIWR_ROOT}"
    printf 'This will chown workspace/ and home/ under it to %s and set it 0700.\n' "${UID_NOW}"
    read -r -p "Continue? [y/N]: " reply || die "Cancelled."
    case "${reply}" in y|Y|yes) ;; *) die "Stopped. Set AIWR_ROOT to somewhere else." ;; esac
  fi
fi

sudo mkdir -p "${AIWR_ROOT}/workspace" "${AIWR_ROOT}/home"
sudo chown "${UID_NOW}:${GID_NOW}" "${AIWR_ROOT}"
# Not the whole root: src/ can sit here, and recursing into source
# repositories would flatten any ownership set inside them.
sudo chown -R "${UID_NOW}:${GID_NOW}" "${AIWR_ROOT}/workspace" "${AIWR_ROOT}/home"
sudo chmod 700 "${AIWR_ROOT}"
ok "workspace/ and home/, owned by ${UID_NOW}, root is 0700"

[ -d "${AIWR_ROOT}/backup" ] \
  && note "${AIWR_ROOT}/backup is left over from the old layout and is no longer used. It may still be your only backup, so check the new one before deleting it."

# Docker creates a directory here if the file is absent, and Claude then fails
# in a way that does not mention it.
# Claude asks three things on a first run: onboarding, whether /workspace is
# trusted, and whether to enable remote control. The service runs with nobody
# attached to its terminal, so any of them would block it forever. Answering
# them here is what lets `make up` work unattended.
#
# Merged into an existing file, not only written to a new one. Seeding only on
# creation silently does nothing on a root that has been used before, which is
# exactly when the answers have been lost.
CFG="${AIWR_ROOT}/home/.claude.json"
if [ ! -s "${CFG}" ]; then
  cat > "${CFG}" <<'JSON'
{
  "hasCompletedOnboarding": true,
  "hasUsedRemoteControl": true,
  "remoteDialogSeen": true,
  "projects": {
    "/workspace": {
      "hasTrustDialogAccepted": true
    }
  }
}
JSON
  chmod 600 "${CFG}"
  did "created home/.claude.json with the first-run questions answered"
elif command -v jq >/dev/null 2>&1; then
  tmp="$(mktemp "${CFG}.XXXXXX")"
  if jq '.hasCompletedOnboarding = true
       | .hasUsedRemoteControl = true
       | .remoteDialogSeen = true
       | .projects["/workspace"].hasTrustDialogAccepted = true' "${CFG}" > "${tmp}" 2>/dev/null; then
    if cmp -s "${tmp}" "${CFG}"; then
      rm -f "${tmp}"
    else
      mv "${tmp}" "${CFG}"; chmod 600 "${CFG}"
      did "answered the first-run questions in home/.claude.json"
    fi
  else
    rm -f "${tmp}"; note "could not read ${CFG}, leaving it alone"
  fi
else
  note "jq is not installed, so ${CFG} was left as it is." \
       "If the service sits there doing nothing, run \`make login\` once."
fi

# The file tools are confined to the working directory, so /src is refused
# without this. A setting rather than --add-dir, so it covers the sessions
# remote-control spawns. Takes effect only once the folder is trusted, which
# hasTrustDialogAccepted above does.
SETTINGS="${AIWR_ROOT}/home/settings.json"
if command -v jq >/dev/null 2>&1; then
  [ -s "${SETTINGS}" ] || printf '{}\n' > "${SETTINGS}"
  tmp="$(mktemp "${SETTINGS}.XXXXXX")"
  if jq '.permissions.additionalDirectories =
           ((.permissions.additionalDirectories // []) + ["/src"] | unique)' \
       "${SETTINGS}" > "${tmp}" 2>/dev/null; then
    if cmp -s "${tmp}" "${SETTINGS}"; then
      rm -f "${tmp}"
      ok "/src is in permissions.additionalDirectories"
    else
      mv "${tmp}" "${SETTINGS}"
      did "added /src to permissions.additionalDirectories in home/settings.json"
    fi
  else
    rm -f "${tmp}"; note "could not read ${SETTINGS}, leaving it alone." \
      "Claude will refuse to touch /src until it lists /src in permissions.additionalDirectories."
  fi
else
  note "jq is not installed, so ${SETTINGS} was left as it is." \
       "Claude will refuse to touch /src until it lists /src in permissions.additionalDirectories."
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

# A repository with no commits has no HEAD, and the backup snapshots onto
# HEAD, so it would fail every hour on a new workspace and report a problem
# that is not one. Give it something to start from.
if ! git -C "${AIWR_ROOT}/workspace" rev-parse -q --verify HEAD >/dev/null 2>&1; then
  git -C "${AIWR_ROOT}/workspace" add .gitignore
  git -C "${AIWR_ROOT}/workspace" \
    -c user.name="ai-workspace-remote" -c user.email="init@localhost" \
    commit -q -m "Initial commit"
  did "made the first commit in workspace/"
fi

echo
echo "Setting up secrets/"
mkdir -p secrets && chmod 700 secrets
if [ ! -s secrets/smb_password ]; then
  smb_pw=""
  if [ -t 0 ]; then
    printf '\nThe SMB share needs a password. Leave it blank to have one generated.\n'
    read -r -s -p "SMB password for user 'claude': " smb_pw
    printf '\n'
  fi
  if [ -n "${smb_pw}" ]; then
    ( umask 077; printf '%s' "${smb_pw}" > secrets/smb_password )
    did "set the SMB password"
  else
    # pipefail off for this one line: head closes the pipe at 24 bytes, tr takes
    # SIGPIPE, and the pipeline would otherwise report failure for working right.
    ( umask 077; set +o pipefail
      LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24 > secrets/smb_password )
    did "generated an SMB password"
  fi
  unset smb_pw
fi
ok "SMB user 'claude', password in secrets/smb_password"

# Created either way: compose mounts it, so a missing file stops the stack.
if [ ! -e secrets/github_token ]; then
  gh_tok=""
  if [ -t 0 ]; then
    printf '\nA GitHub token lets the agent clone, push and open pull requests\n'
    printf 'from /src. Leave it blank to skip, and add it later by writing\n'
    printf 'secrets/github_token yourself.\n\n'
    # The permissions and a name are prefilled from the query string, so the
    # only thing left to pick is which repositories it covers.
    printf 'Generate one here, then pick the repositories it covers:\n'
    printf '  https://github.com/settings/personal-access-tokens/new'
    printf '?name=ai-workspace-remote&contents=write&pull_requests=write\n\n'
    printf 'Those permissions also allow merging. Protect any branch you do not\n'
    printf 'want merged without a review.\n'
    read -r -s -p "GitHub token (blank to skip): " gh_tok
    printf '\n'
  fi
  ( umask 077; printf '%s' "${gh_tok}" > secrets/github_token )
  if [ -n "${gh_tok}" ]; then did "stored the GitHub token"; else did "created an empty secrets/github_token, so no GitHub access"; fi
  unset gh_tok
fi
if [ -s secrets/github_token ]; then
  ok "GitHub token in secrets/github_token"
else
  note "no GitHub token, so gh and git push will not be authenticated." \
       "Write secrets/github_token and run \`make up\` to add one."
fi

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

# Whoever finds this in five years, on a disk in a drawer, will have no idea
# what it is. Two bare repositories and a directory of JSONL is not
# self-explanatory.
cat > "${BACKUP_MOUNT}/README.md" <<'MD'
# Backup of an ai-workspace

Written by ai-workspace-remote, which runs Claude Code against a workspace of
markdown notes and keeps a copy here.

https://github.com/sebmartin/ai-workspace-remote

## What is here

- `workspace.git`  a bare git repository holding the workspace.
- `claude-home/`   Claude Code session transcripts, as JSONL. No credentials.
- `.aiwr-backup`   a marker. The jobs refuse to write if it is missing, which
                   is how they tell "the storage is mounted" from "this is an
                   empty directory where the storage should have been".

## Getting the files back

`workspace.git` has two branches. `main` is what was committed by hand.
`backup` is `main` plus one commit holding whatever had not been committed
yet, so it is the newer of the two.

    git clone this-directory/workspace.git restored
    cd restored
    git checkout origin/backup -- .
    git reset

That checks out `main`, lays the newer files over it, and leaves them as
uncommitted changes, which is the state the workspace was in.

Nothing needs to be installed on whatever machine holds this. It only ever
receives files.
MD
did "wrote ${BACKUP_MOUNT}/README.md"

# Last, so it is only ever there once everything above worked. The jobs treat
# its absence as "the storage is not mounted" and refuse to write.
touch "${BACKUP_MOUNT}/.aiwr-backup"
ok "backup storage ready and marked"

echo
echo "Setting up ${SRC_DIR}"

# Docker would otherwise create it as root, leaving Claude unable to write.
if [ -z "${SRC_MOUNT}" ]; then
  sudo mkdir -p "${SRC_DIR}"
  sudo chown "${UID_NOW}:${GID_NOW}" "${SRC_DIR}"
else
  # No sudo, so that creating it proves the container's uid can write there.
  mkdir -p "${SRC_DIR}" 2>/dev/null \
    || die "Cannot create ${SRC_DIR}." "Create it yourself, or point SRC_MOUNT somewhere writable by $(id -un)."
fi
ok "source repositories, mounted at /src"

# Never overwritten: an existing one knows more about how the directory is
# used than this script does.
if [ ! -e "${SRC_DIR}/CLAUDE.md" ]; then
  cat > "${SRC_DIR}/CLAUDE.md" <<'MD'
# /src

Source repositories, for coding work. Clone them here, one directory each.

This is not the workspace. `/workspace` holds the markdown threads this
machine exists to keep, and it is snapshotted hourly and shared over SMB.
`/src` is neither of those things, and **nothing backs it up**: a repository
here exists only on this machine until its commits are pushed. So push.

Replace this file with whatever is actually useful. Nothing overwrites it.
MD
  did "wrote a starter CLAUDE.md in the source directory"
fi

note "/src is not backed up. Push your work, or it only exists on this machine."

echo
echo "Ready. Review .env if you want to change anything, then:"
echo "  make login"
echo "  make up"
