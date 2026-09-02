#!/bin/bash
# Mirror Claude Code's session transcripts to the NAS, so session history
# survives losing the box entirely.
#
# Deliberately not part of the git repo: transcripts are append-only JSONL
# that grow steadily, and committing them every cycle would store a fresh
# full blob of a growing file each time. Nobody wants their history either -
# only the latest copy matters.

JOB=transcripts
. /opt/aiwr/lib.sh

SRC="/claude-home"

# This is an ALLOWLIST, and the terminal --exclude='*' is what makes it one.
# An exclude list would be correct only for the files that exist today and
# would silently start copying anything a future Claude Code release adds to
# ~/.claude - including new credential material.
#
# These paths are hardcoded on purpose. No environment variable widens this
# set, so a .env edit cannot put secrets on the NAS.
FILTER=(
  --include='projects/'            --include='projects/**'
  --include='todos/'               --include='todos/**'
  --include='file-history/'        --include='file-history/**'
  --include='history.jsonl'
  --include='plugins/'
  --include='plugins/known_marketplaces.json'
  --include='plugins/installed_plugins.json'
  --exclude='*'
)

# Never copied, and there is no flag to turn any of them on:
#   .credentials.json  OAuth refresh tokens
#   .claude.json       holds oauthAccount and machineID (and lives outside
#                      SRC anyway, so it is doubly out of scope)
#   settings.json      can carry an env block with API keys
# Everything else falls to the terminal exclude above.
FORBIDDEN_BASENAMES='^(\.credentials\.json|\.claude\.json|settings\.json|settings\.local\.json|\.netrc|\.npmrc|id_rsa|id_ed25519|id_ecdsa)$|\.(pem|key|p12|pfx)$'

# A filter is one typo away from being wrong, so check what rsync actually
# intends to send before sending any of it.
guard() {
  local listing offenders
  listing="$(rsync -a --dry-run --out-format='%n' --prune-empty-dirs \
               "${FILTER[@]}" "${SRC}/" /tmp/guard-dest/ 2>/dev/null || true)"

  offenders="$(printf '%s\n' "${listing}" \
    | sed 's:/*$::' \
    | awk -F/ 'NF {print $NF}' \
    | grep -E "${FORBIDDEN_BASENAMES}" || true)"

  if [ -n "${offenders}" ]; then
    log error guard_tripped "the filter would send credential-bearing files; nothing was transferred"
    printf '%s\n' "${offenders}" | sed 's/^/  offender=/'
    return 1
  fi
}

run() {
  [ -d "${SRC}" ] || { log error missing_source "path=${SRC}"; return 1; }

  mkdir -p /tmp/guard-dest
  guard || return 1

  local ssh dest
  ssh="$(ssh_cmd)"
  dest="${NAS_USER}@${NAS_HOST}:${NAS_TRANSCRIPTS_PATH}"

  # No --delete. If Claude prunes an old session locally the copy is still
  # wanted, which is precisely the catastrophic-failure case this covers.
  # The archive grows, so watch it.
  #
  # A live session's .jsonl is being appended while rsync reads it, so a copy
  # can end mid-line. JSONL tolerates that - the partial record is discarded
  # on read and the next run picks up the complete file.
  timeout 900 rsync -a --partial --timeout=600 --prune-empty-dirs --stats \
    -e "${ssh}" "${FILTER[@]}" \
    "${SRC}/" "${dest}/" | grep -E '^(Number of regular files transferred|Total transferred)' || true

  info mirrored "dest=${dest}"
  record_success
}

# `|| rc=$?` puts the call in a condition context. Without it errexit
# fires the ERR trap on a lock timeout and the handling below is dead.
rc=0
with_lock "${TRANSCRIPTS_LOCK}" run || rc=$?
if [ $rc -eq 75 ]; then
  warn skipped "reason=lock_held"
  exit 0
fi
exit $rc
