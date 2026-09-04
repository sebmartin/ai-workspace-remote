#!/bin/bash
# Repack both repos and verify the backup.
#
# The backup repo needs it because the `backup` ref is rewritten on every run,
# so the commits it used to point at pile up unreachable. The workspace repo
# needs it for the same reason: those commits are created there and nothing
# local references them.

JOB=maintain
. /opt/aiwr/lib.sh

run() {
  # The workspace first, and unconditionally. Local hygiene should not be
  # skipped for a week because the backup storage is unplugged.
  #
  # Default prune expiry, never --prune=now. Git will not prune an object
  # younger than gc.pruneExpire precisely so a concurrent writer that has
  # created an object but not yet pointed a ref at it stays safe, and that
  # protection is the reason this job needs no lock of its own.
  git_ws gc --quiet
  info gc "repo=workspace loose=$(git_ws count-objects -v | awk '/^count:/ {print $2}')"

  require_dest

  # fsck before gc, not after. On an already-corrupt repo a broken ref can
  # make live objects look unreachable, and a gc would then prune them.
  if ! git_dest fsck --full --strict --no-progress --no-dangling; then
    log error fsck_failed "skipping the gc so it cannot prune live objects"
    warn_set "The backup repository failed its integrity check" \
      "\`git fsck\` reported problems in ${DEST_GIT_DIR}. The weekly repack was skipped, because repacking a corrupt repository can delete objects that are still needed. New snapshots are still being written." \
      "git --git-dir=${DEST_GIT_DIR} fsck --full"
    exit 1
  fi

  local before after
  before="$(git_dest count-objects -vH | awk '/size-pack/ {print $2 $3}')"
  git_dest gc --quiet
  after="$(git_dest count-objects -vH | awk '/size-pack/ {print $2 $3}')"
  info gc "repo=backup size_pack_before=${before} size_pack_after=${after}"

  warn_clear
}

run
