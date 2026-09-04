#!/bin/bash
# Push the workspace to the backup repo on the mounted storage: every real
# branch as-is, plus a `backup` ref holding whatever is not committed yet.
#
# That ref is rewritten on every run rather than appended to. It is always
# exactly HEAD plus one commit, so the only blobs it keeps alive are the
# current uncommitted diff. Yesterday's half-finished edits become
# unreachable as soon as the ref moves, and the weekly gc reclaims them.
#
# Uses plumbing against a private index, so it never touches the checked-out
# branch, the working index or HEAD. It cannot collide with a git command
# someone runs in the workspace, and there is no local `backup` branch to
# get in the way.

JOB=commit
. /opt/aiwr/lib.sh

BRANCH=backup

# A private index, so this never touches the one you use. /tmp is a tmpfs and
# a fresh index costs only a slower first `add -A`.
#
# A fixed name is safe here. It only has to be unique inside one container's
# own tmpfs, and this is the only thing that writes it. If two runs ever did
# overlap, say an hourly tick landing on a `make backup-now`, git takes an
# index.lock of its own and the second run fails loudly rather than producing
# a half-merged tree.
export GIT_INDEX_FILE=/tmp/snapshot.index

run() {
  local head tree target

  # Before anything writes an object. `add -A` against a missing destination
  # would leave loose objects in the workspace repo that nothing ever
  # references, every hour, until a gc clears them.
  require_dest

  # Keep the backup repo's HEAD pointing at the same branch as the workspace,
  # since `git init --bare` leaves it at refs/heads/master and a clone of the
  # restored copy would check out nothing. Skipped on a detached HEAD, where
  # there is no branch to name and symbolic-ref exits non-zero.
  local ws_head
  if ws_head="$(git_ws symbolic-ref -q HEAD)"; then
    git_dest symbolic-ref HEAD "${ws_head}"
  else
    warn detached_head "not syncing the backup repo's HEAD"
  fi

  if git_ws show-ref -q --verify "refs/heads/${BRANCH}"; then
    log error branch_collision \
      "a local branch named '${BRANCH}' exists and collides with the ref this job force-pushes"
    return 1
  fi

  head="$(git_ws rev-parse -q --verify HEAD)" \
    || { log error no_head "the workspace has no commits yet"; return 1; }

  git_ws add -A
  tree="$(git_ws write-tree)"

  if [ "$(git_ws rev-parse "${head}^{tree}")" = "${tree}" ]; then
    # Nothing uncommitted. Point the ref at HEAD so it stops holding an old
    # diff alive.
    target="${head}"
  else
    # Both dates are pinned to the parent's and the message carries no
    # timestamp, so an unchanged tree hashes to the same commit every run.
    # The ref does not move and the push is a no-op, with no comparison
    # against the previous value needed to work that out.
    local when
    when="$(git_ws show -s --format=%cI "${head}")"
    target="$(GIT_AUTHOR_DATE="${when}" GIT_COMMITTER_DATE="${when}" \
              git_ws commit-tree "${tree}" -p "${head}" -m "uncommitted work")"
  fi

  # The backup ref goes first. `push --all` is fast-forward only and fails
  # after any amend or rebase of an already-pushed branch, and that failure
  # would otherwise take the snapshot down with it.
  #
  # Pushed by path, not via a configured remote. A named remote would keep a
  # remote-tracking ref whose reflog records every force-push, and those
  # entries hold every superseded commit reachable, so the workspace repo
  # would grow without bound while the backup stayed lean. Measured at 10x on
  # a 200KB file over 10 rounds.
  git_ws push -q --force "${DEST_GIT_DIR}" "${target}:refs/heads/${BRANCH}"
  info backup_ref "sha=$(git_ws rev-parse --short "${target}")"

  git_ws push -q "${DEST_GIT_DIR}" --all

  # Reached only if both pushes returned zero.
  warn_clear
}

run
