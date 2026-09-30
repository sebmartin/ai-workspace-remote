#!/bin/bash
# Two questions. Are the jobs still being run at all, and did the last one
# leave a fault. Anything worth reading is a file in WARNINGS/, in the
# workspace, where a person actually looks.

set -uo pipefail

WARNINGS=/workspace/WARNINGS

pgrep -x supercronic >/dev/null 2>&1 \
  || { echo "unhealthy: supercronic is not running, so no job is being scheduled"; exit 1; }

# Counting `*.md` rather than asking whether the directory is empty. The
# workspace is served over SMB, so macOS drops `.DS_Store` into any directory
# it is shown, and a non-empty test would then report unhealthy forever with
# no fault present.
#
# Only this repo's own faults. Another tool writing here, or into a thread,
# is not this container's health to report.
shopt -s nullglob
faults=("${WARNINGS}"/backup-*.md)
if [ ${#faults[@]} -gt 0 ]; then
  echo "unhealthy: see ${WARNINGS}/ in the workspace"
  printf '  %s\n' "${faults[@]##*/}"
  exit 1
fi

echo healthy
