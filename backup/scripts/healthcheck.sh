#!/bin/bash
# Two questions. Are the jobs still being run at all, and did the last one
# leave a warning. Anything worth reading is in WARNINGS.md, in the workspace,
# where a person actually looks.

set -uo pipefail

pgrep -x supercronic >/dev/null 2>&1 \
  || { echo "unhealthy: supercronic is not running, so no job is being scheduled"; exit 1; }

if [ -f /workspace/WARNINGS.md ]; then
  echo "unhealthy: see WARNINGS.md in the workspace"
  exit 1
fi

echo healthy
