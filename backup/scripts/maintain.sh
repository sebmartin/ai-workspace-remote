#!/bin/bash
# Repack both repos and verify the bare one.
#
# The bare repo needs it because the backup ref is rewritten on every run, so
# the commits it used to point at pile up unreachable, and without a gc the
# mirror gets slower forever. The workspace repo needs it for the same
# reason: those commits are created there and nothing local references them.
#
# Without the fsck, rsync replicates corruption as faithfully as it does data
# and nothing on the NAS side would ever notice.

JOB=maintain
. /opt/aiwr/lib.sh

run() {
  local before after
  before="$(git_bare count-objects -vH | awk '/size-pack/ {print $2 $3}')"

  git_bare gc --prune=now --quiet
  after="$(git_bare count-objects -vH | awk '/size-pack/ {print $2 $3}')"
  info gc "repo=bare size_pack_before=${before} size_pack_after=${after}"

  # Default prune expiry here, not --prune=now. The lock only serialises our
  # own jobs, and someone may be running git in the workspace right now.
  git_ws gc --quiet
  info gc "repo=workspace loose=$(git_ws count-objects -v | awk '/^count:/ {print $2}')"

  if ! git_bare fsck --full --strict --no-progress --no-dangling; then
    log error fsck_failed "marking corrupt; mirroring is blocked until cleared"
    date -Is > "${CORRUPT_MARKER}"
    return 1
  fi

  info fsck_ok
  record_success
}

with_lock "${GIT_LOCK}" run
rc=$?
if [ $rc -eq 75 ]; then
  log error lock_timeout "waited=${LOCK_WAIT}s"
  record_failure 75
  exit 1
fi
exit $rc
