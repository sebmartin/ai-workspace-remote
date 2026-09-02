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
  cd "${WORKSPACE}"

  local head tree existing target
  head="$(git_ws rev-parse -q --verify HEAD)" \
    || { log error no_head "the workspace has no commits yet"; return 1; }

  git_ws add -A
  tree="$(git_ws write-tree)"
  existing="$(git_bare rev-parse -q --verify "refs/heads/${BRANCH}" || true)"

  if [ "$(git_ws rev-parse "${head}^{tree}")" = "${tree}" ]; then
    # Nothing uncommitted. Point the ref at HEAD so it stops holding an old
    # diff alive.
    target="${head}"

  elif [ -n "${existing}" ] \
       && [ "$(git_bare rev-parse -q --verify "${existing}^{tree}" || true)" = "${tree}" ] \
       && [ "$(git_bare rev-parse -q --verify "${existing}^" || true)" = "${head}" ]; then
    # Same uncommitted state as last time. Reuse the commit rather than
    # minting a new sha for an identical tree, which would rewrite the ref
    # and give the mirror something to ship every single hour.
    target="${existing}"

  else
    target="$(git_ws commit-tree "${tree}" -p "${head}" \
                -m "uncommitted work at $(date -Is)")"
  fi

  # Pushed to the bare repo by path, not via a configured remote. A named
  # remote would keep a remote-tracking ref whose reflog records every
  # force-push, and those entries hold every superseded commit reachable, so
  # the workspace repo would grow without bound while the bare repo stayed
  # lean. Measured at 10x on a 200KB file over 10 rounds.
  #
  # --all first: your real branches, fast-forward only, so a rewritten
  # history upstream surfaces as an error rather than being clobbered.
  git_ws push -q "${BACKUP_GIT_DIR}" --all

  if [ "${target}" = "${existing}" ]; then
    info unchanged
  else
    # --force because this ref is rewritten by design.
    git_ws push -q --force "${BACKUP_GIT_DIR}" "${target}:refs/heads/${BRANCH}"
    info updated "ref=${BRANCH} sha=$(git_ws rev-parse --short "${target}")"
  fi

  # Reached only if the pushes returned zero.
  record_success
}

with_lock "${GIT_LOCK}" run
rc=$?
if [ $rc -eq 75 ]; then
  # Another git job holds the lock. The next tick retries, and a lock held
  # long enough to matter shows up as staleness in the healthcheck.
  warn skipped "reason=lock_held"
  exit 0
fi
exit $rc
