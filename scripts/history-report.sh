#!/bin/bash
# Summarizes real use from turnstile's history: jobs, queue waits, runs saved by merging, pauses, kills, and peaks.
#
#   ./scripts/history-report.sh              # ~/.turnstile, or $TURNSTILE_HOME
#   ./scripts/history-report.sh --days 7
set -u

HOME_DIR="${TURNSTILE_HOME:-$HOME/.turnstile}"
DB="$HOME_DIR/state.sqlite"
LOG="$HOME_DIR/daemon.log"
DAYS=30
[ "${1:-}" = "--days" ] && DAYS="${2:?days}"
[ -f "$DB" ] || { echo "no history at $DB" >&2; exit 1; }

SINCE="strftime('%s', 'now') - $DAYS * 86400"
q() { sqlite3 -separator ' | ' "file:$DB?mode=ro" "$@"; }

echo "# turnstile history, last $DAYS days"
echo
q "SELECT 'Jobs: ' || COUNT(*) || ', across ' || COUNT(DISTINCT root) || ' projects, from ' ||
   datetime(MIN(queued_at), 'unixepoch', 'localtime') || ' to ' || datetime(MAX(queued_at), 'unixepoch', 'localtime') ||
   '. Agent jobs: ' || SUM(agent) || '.' FROM jobs WHERE queued_at >= $SINCE"
echo

echo "## Outcomes"
echo
echo "| Outcome | Jobs |"
echo "| --- | --- |"
q "SELECT '| ' || outcome || ' | ' || COUNT(*) || ' |' FROM jobs WHERE queued_at >= $SINCE AND outcome IS NOT NULL
   GROUP BY outcome ORDER BY COUNT(*) DESC"
echo
q "SELECT 'Runs saved by merging: ' || SUM(outcome = 'joined') || ' joined an identical run, ' ||
   SUM(outcome = 'superseded') || ' were replaced by a newer request.' FROM jobs WHERE queued_at >= $SINCE"
echo

echo "## Queue waits"
echo
# Percentiles in SQL: the value at the given rank of the sorted waits.
waits="SELECT started_at - queued_at AS w FROM jobs WHERE queued_at >= $SINCE AND started_at IS NOT NULL"
count=$(q "SELECT COUNT(*) FROM ($waits)")
if [ "$count" -gt 0 ]; then
  pct() { q "SELECT printf('%.1f', w) FROM ($waits) ORDER BY w LIMIT 1 OFFSET MIN($count - 1, CAST($1 * $count AS INT))"; }
  echo "| Started jobs | p50 | p90 | max | waited over 60s | waited over 120s |"
  echo "| --- | --- | --- | --- | --- | --- |"
  echo "| $count | $(pct 0.5)s | $(pct 0.9)s | $(q "SELECT printf('%.0f', MAX(w)) FROM ($waits)")s | $(q "SELECT SUM(w > 60) FROM ($waits)") | $(q "SELECT SUM(w > 120) FROM ($waits)") |"
  echo
  echo "Waits over 120s matter to agents: harness timeouts (Claude Code's default is 2 minutes) include queue time."
fi
echo

echo "## Pauses and kills"
echo
if [ -f "$LOG" ]; then
  echo "- Paused for memory: $(grep -c ' paused at ' "$LOG")"
  echo "- Paused by a person: $(grep -c ' paused by request' "$LOG")"
  echo "- Killed as runaways: $(grep -cE '#[0-9]+ [^ ]+: killed ' "$LOG")"
  echo "- Killed by a person: $(grep -c 'killed by request' "$LOG")"
  grep -E '#[0-9]+ [^ ]+: killed ' "$LOG" | sed -E 's/^([^ ]+) (.*)/  - \1: \2/' | tail -10
else
  echo "No daemon log at $LOG."
fi
echo

echo "## Peaks by command"
echo
echo "| Command | Runs | Median peak | Max peak | Median run time |"
echo "| --- | --- | --- | --- | --- |"
q "WITH r AS (SELECT key, peak, finished_at - started_at AS t,
     ROW_NUMBER() OVER (PARTITION BY key ORDER BY peak) AS pr,
     ROW_NUMBER() OVER (PARTITION BY key ORDER BY finished_at - started_at) AS tr,
     COUNT(*) OVER (PARTITION BY key) AS n
   FROM jobs WHERE queued_at >= $SINCE AND peak > 0 AND started_at IS NOT NULL AND finished_at IS NOT NULL)
   SELECT '| ' || key || ' | ' || MAX(n) || ' | ' ||
     printf('%.0f MB', MAX(CASE WHEN pr = (n + 1) / 2 THEN peak END) / 1048576.0) || ' | ' ||
     printf('%.0f MB', MAX(peak) / 1048576.0) || ' | ' ||
     printf('%.0fs', MAX(CASE WHEN tr = (n + 1) / 2 THEN t END)) || ' |'
   FROM r GROUP BY key ORDER BY MAX(peak) DESC LIMIT 20"
