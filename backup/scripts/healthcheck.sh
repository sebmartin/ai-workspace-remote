#!/bin/bash
# Turns a silent 3am cron failure into an unhealthy container, which shows up
# in `docker ps` and in any dashboard watching it.

set -uo pipefail
STATE_DIR="/backup/state"

fail() { echo "unhealthy: $*"; exit 1; }

[ -f "${STATE_DIR}/corrupt" ] && fail "bare repo marked corrupt at $(cat "${STATE_DIR}/corrupt"); mirroring is blocked"

now="$(date +%s)"
# Before a job has ever succeeded, measure from container start rather than
# from the epoch, so a slow first run is not reported as a failure.
boot="$(cat "${STATE_DIR}/boot_at" 2>/dev/null || echo "${now}")"

check() {
  local job="$1" threshold="$2" last age
  [ "${threshold}" -gt 0 ] 2>/dev/null || return 0
  last="$(cat "${STATE_DIR}/last_success_${job}" 2>/dev/null || echo "${boot}")"
  age=$(( now - last ))
  if [ "${age}" -gt "${threshold}" ]; then
    fail "${job} has not succeeded in ${age}s (threshold ${threshold}s)"
  fi
}

# Just over two hours for the hourly snapshot, 48 hours for the rsyncs.
check commit       8000
check mirror      172800
check transcripts 172800

echo "healthy"
