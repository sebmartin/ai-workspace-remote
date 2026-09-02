#!/bin/bash
# Push the workspace to the local bare repo: every real branch as-is, plus a
# `backup` ref holding whatever is not committed yet.
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
export GIT_INDEX_FILE="${STATE_DIR}/snapshot.index"

run() {
  local head tree target

  # Keep the bare repo's HEAD pointing at the same branch as the workspace.
  # `git init --bare` leaves it at refs/heads/master, and nothing else ever
  # sets it, so a clone of the restored copy checks out nothing at all.
  git_bare symbolic-ref HEAD "$(git_ws symbolic-ref HEAD)"

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
  # Pushed to the bare repo by path, not via a configured remote. A named
  # remote would keep a remote-tracking ref whose reflog records every
  # force-push, and those entries hold every superseded commit reachable, so
  # the workspace repo would grow without bound while the bare repo stayed
  # lean. Measured at 10x on a 200KB file over 10 rounds.
  git_ws push -q --force "${BACKUP_GIT_DIR}" "${target}:refs/heads/${BRANCH}"
  info backup_ref "sha=$(git_ws rev-parse --short "${target}")"

  git_ws push -q "${BACKUP_GIT_DIR}" --all

  # Reached only if both pushes returned zero.
  record_success
}

# `|| rc=$?` puts the call in a condition context. Without it errexit
# fires the ERR trap on a lock timeout and the handling below is dead.
rc=0
with_lock "${GIT_LOCK}" run || rc=$?
if [ $rc -eq 75 ]; then
  # Another git job holds the lock. The next tick retries, and a lock held
  # long enough to matter shows up as staleness in the healthcheck.
  warn skipped "reason=lock_held"
  exit 0
fi
exit $rc
