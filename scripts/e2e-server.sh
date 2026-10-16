#!/bin/bash
# Controls escaped E2E servers by a validated, per-run argv token. The marker is
# passed in the environment so this helper's own argv cannot match its target.
set -u

if [ "$#" -ne 1 ] || { [ "$1" != exists ] && [ "$1" != stop ]; } ||
  [[ ! "${TURNSTILE_E2E_SERVER_MARKER:-}" =~ ^turnstile-e2e-server-[a-zA-Z0-9]{6}$ ]]; then
  echo "Usage: TURNSTILE_E2E_SERVER_MARKER=<run-marker> e2e-server.sh <exists|stop>" >&2
  exit 2
fi

pattern="(^|[[:space:]])${TURNSTILE_E2E_SERVER_MARKER}([[:space:]]|$)"
if [ "$1" = exists ]; then
  pgrep -f "$pattern" > /dev/null
else
  pkill -f "$pattern"
  status=$?
  # No matching server is already clean; other process-lookup errors still fail.
  [ "$status" -eq 1 ] && exit 0
  exit "$status"
fi
