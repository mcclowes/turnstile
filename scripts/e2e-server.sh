#!/bin/bash
# Detects or stops only the escaped server with this run's exact argv marker.
set -euo pipefail

usage() { echo "Usage: e2e-server.sh check|stop turnstile-e2e-server-<alphanumeric-id>" >&2; exit 2; }
[ "$#" -eq 2 ] || usage
action=$1 tag=$2
[[ "$tag" =~ ^turnstile-e2e-server-[[:alnum:]]+$ ]] || usage
pattern="(^|[[:space:]])${tag}([[:space:]]|$)"

case "$action" in
  check) exec /usr/bin/pgrep -f "$pattern" > /dev/null ;;
  stop) exec /usr/bin/pkill -f "$pattern" ;;
  *) usage ;;
esac
