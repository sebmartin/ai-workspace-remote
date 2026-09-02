#!/bin/bash
# Ship the local bare repo to the NAS as plain files. The NAS never runs git.

JOB=mirror
. /opt/aiwr/lib.sh

run() {
  if [ -f "${CORRUPT_MARKER}" ]; then
    # Do not overwrite the last known-good copy with a corrupt one.
    log error refused "reason=fsck_marker path=${CORRUPT_MARKER}"
    return 1
  fi

  git_bare fsck --connectivity-only --no-progress --no-dangling >/dev/null 2>&1 || {
    log error fsck_failed "marking corrupt; mirroring is blocked until cleared"
    date -Is > "${CORRUPT_MARKER}"
    return 1
  }

  local ssh dest
  ssh="$(ssh_cmd)"
  dest="${NAS_USER}@${NAS_HOST}:${NAS_PATH}"

  # Two passes, objects before refs. A single --delete pass over a live git
  # directory can land refs before the objects they point at, or delete a
  # pack that the new refs still need - leaving the copy unclonable, and
  # permanently so if the source disk dies inside that window.
  # --partial-dir, not bare --partial: a resumable chunk belongs in a scratch
  # directory, not left in place under the real filename where git would read
  # it as a truncated pack.
  info pass1 "dest=${dest}"
  timeout 900 rsync -a --partial-dir=.rsync-partial --timeout=600 -e "${ssh}" \
    --exclude='refs/***' \
    --exclude='packed-refs' \
    --exclude='HEAD' \
    --exclude='objects/tmp_*' \
    --exclude='*.lock' \
    "${BACKUP_GIT_DIR}/" "${dest}/"

  # Output to a file rather than a pipe. `rsync | grep || true` discards the
  # exit status pipefail preserved, so a failed transfer would report success.
  info pass2 "dest=${dest}"
  timeout 900 rsync -a --delete-after --partial-dir=.rsync-partial --timeout=600 --stats \
    -e "${ssh}" \
    --exclude='.rsync-partial' \
    --exclude='objects/tmp_*' \
    --exclude='*.lock' \
    "${BACKUP_GIT_DIR}/" "${dest}/" > /tmp/mirror.out
  grep -E '^(Total transferred|Total file size)' /tmp/mirror.out || true

  info mirrored "dest=${dest}"
  record_success
}

# Unlike the snapshot, a job this infrequent failing to get the lock is a
# real problem rather than something the next tick fixes.
take_lock "${GIT_LOCK}" || { log error lock_timeout "waited=${LOCK_WAIT}s"; record_failure 75; exit 1; }
run
