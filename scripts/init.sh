#!/bin/bash
# One-time setup, and the way to check an existing one. Everything here is
# idempotent, so re-running it is how you ask "am I set up correctly?".
#
# It does the mechanical work and stops with a named problem when it cannot.
# Nothing in here is something the reader has to remember.

set -Eeuo pipefail

cd "$(dirname "$0")/.."
ENV_FILE=.env

ok()   { printf '  \033[32mok\033[0m    %s\n' "$1"; }
did()  { printf '  \033[36mdid\033[0m   %s\n' "$1"; }
die()  { printf '\n\033[31m%s\033[0m\n' "$1" >&2; [ $# -gt 1 ] && printf '%s\n' "$2" >&2; exit 1; }

[ -f "${ENV_FILE}" ] || die "No .env file." "Run: cp .env.example .env"

# Read a key without sourcing, so a stray line in .env cannot execute.
get() { sed -n "s/^$1=//p" "${ENV_FILE}" | tail -1 | sed 's/[[:space:]]*$//'; }

# Rewrite a key in place, appending it if it is not there yet.
set_key() {
  if grep -q "^$1=" "${ENV_FILE}"; then
    sed -i.bak "s|^$1=.*|$1=$2|" "${ENV_FILE}" && rm -f "${ENV_FILE}.bak"
  else
    printf '%s=%s\n' "$1" "$2" >> "${ENV_FILE}"
  fi
}

echo "Checking .env"

AIWR_ROOT="$(get AIWR_ROOT)"
case "${AIWR_ROOT}" in
  /?*) ;;
  "")  die "AIWR_ROOT is not set in .env." "It is the one directory this stack owns. For example: /srv/ai-workspace" ;;
  *)   die "AIWR_ROOT must be an absolute path, got '${AIWR_ROOT}'." ;;
esac
ok "AIWR_ROOT=${AIWR_ROOT}"

missing=()
for k in NAS_HOST NAS_USER NAS_ROOT; do
  [ -n "$(get "$k")" ] || missing+=("$k")
done
if [ ${#missing[@]} -gt 0 ]; then
  die "Not set in .env: ${missing[*]}" "These say where the backup goes. There is no sensible default for them."
fi
ok "backup target: $(get NAS_USER)@$(get NAS_HOST):$(get NAS_ROOT)"

# The uid is whoever runs this, which is also who will own the tree. Writing it
# down keeps the containers aligned with the files without anyone typing it.
UID_NOW="$(id -u)"; GID_NOW="$(id -g)"
if [ "$(get WORKSPACE_UID)" != "${UID_NOW}" ] || [ "$(get WORKSPACE_GID)" != "${GID_NOW}" ]; then
  set_key WORKSPACE_UID "${UID_NOW}"
  set_key WORKSPACE_GID "${GID_NOW}"
  did "recorded WORKSPACE_UID=${UID_NOW} WORKSPACE_GID=${GID_NOW}"
else
  ok "WORKSPACE_UID=${UID_NOW} WORKSPACE_GID=${GID_NOW}"
fi

echo
echo "Setting up ${AIWR_ROOT}"

if [ ! -d "${AIWR_ROOT}" ]; then
  sudo mkdir -p "${AIWR_ROOT}"
  did "created ${AIWR_ROOT}"
fi
sudo mkdir -p "${AIWR_ROOT}/workspace" "${AIWR_ROOT}/home/.claude" "${AIWR_ROOT}/backup"
sudo chown -R "${UID_NOW}:${GID_NOW}" "${AIWR_ROOT}"
sudo chmod 700 "${AIWR_ROOT}"
ok "workspace/ home/ backup/, owned by ${UID_NOW}, root is 0700"

# Docker creates a directory here if the file is absent, and Claude then fails
# in a way that does not mention it.
if [ ! -s "${AIWR_ROOT}/home/.claude.json" ]; then
  printf '{}' > "${AIWR_ROOT}/home/.claude.json"
  chmod 600 "${AIWR_ROOT}/home/.claude.json"
  did "created home/.claude.json"
fi

# The backup container refuses to start against a directory that is not a repo,
# so an empty workspace has to become one here rather than in a crash loop.
if [ ! -d "${AIWR_ROOT}/workspace/.git" ]; then
  if [ -n "$(ls -A "${AIWR_ROOT}/workspace" 2>/dev/null)" ]; then
    die "${AIWR_ROOT}/workspace has files in it but is not a git repository." \
        "Either run 'git init' there yourself, or move those files aside and copy in a workspace that is already a repo."
  fi
  git init -q -b main "${AIWR_ROOT}/workspace"
  did "git init workspace/"
fi
if [ ! -f "${AIWR_ROOT}/workspace/.gitignore" ]; then
  printf '.DS_Store\n._*\n.Spotlight-V100\n.Trashes\n' > "${AIWR_ROOT}/workspace/.gitignore"
  did "wrote a starter workspace/.gitignore"
fi

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

if [ ! -s secrets/id_backup ]; then
  ssh-keygen -q -t ed25519 -N '' -C "ai-workspace-remote backup" -f secrets/id_backup
  did "generated secrets/id_backup"
fi

NAS_HOST="$(get NAS_HOST)"; NAS_PORT="$(get NAS_PORT)"; NAS_PORT="${NAS_PORT:-22}"
if [ ! -s secrets/known_hosts ]; then
  if ssh-keyscan -p "${NAS_PORT}" "${NAS_HOST}" > secrets/known_hosts 2>/dev/null && [ -s secrets/known_hosts ]; then
    did "scanned the host key for ${NAS_HOST}:${NAS_PORT}"
  else
    rm -f secrets/known_hosts
    die "Could not reach ${NAS_HOST} on port ${NAS_PORT}." \
        "Check NAS_HOST and NAS_PORT in .env, then run make init again."
  fi
fi
ok "secrets/ is 0700, key and known_hosts present"

echo
if ssh -i secrets/id_backup -p "${NAS_PORT}" -o IdentitiesOnly=yes -o BatchMode=yes \
       -o StrictHostKeyChecking=yes -o UserKnownHostsFile=secrets/known_hosts \
       -o ConnectTimeout=10 "$(get NAS_USER)@${NAS_HOST}" \
       "mkdir -p '$(get NAS_ROOT)'" 2>/dev/null; then
  ok "backup target reachable, $(get NAS_ROOT) exists"
  echo
  echo "Ready. Next:"
  echo "  make up"
  echo "  make login"
else
  echo "Ready except for one thing you have to do yourself:"
  echo
  echo "  ssh-copy-id -i secrets/id_backup.pub -p ${NAS_PORT} $(get NAS_USER)@${NAS_HOST}"
  echo
  echo "That needs your NAS password, so it cannot be done here. Then:"
  echo "  make init     # confirms the backup target and creates $(get NAS_ROOT)"
  echo "  make up"
  echo "  make login"
fi
