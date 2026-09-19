#!/bin/bash
# Benchmark: three simulated agents, each running a build and a test lane at once, through turnstile.
# Without turnstile the same load uses up memory and never finishes, so there's nothing to time; that arm only
# runs with BENCH_UNGATED=1, and only on a machine you can afford to lose for a few minutes.
# Jobs hold incompressible memory and keep touching it, so an oversubscribed machine swaps instead of compressing.
# Tests assert on their own run time, so starvation shows up as failures, the way it does for real suites.
#
#   ./scripts/bench.sh                 # gated arm, results in .build/bench/<timestamp>/
#   BENCH_FACTOR=1.1 ./scripts/bench.sh
#   BENCH_UNGATED=1 ./scripts/bench.sh # also run ungated
#
# Sizing: total demand across all lanes is BENCH_FACTOR (default 1.3) times the memory free at the start.
# Each arm stops after BENCH_CAP seconds (default 240). A watchdog aborts an arm as soon as memory is under 10% free,
# swap has grown by BENCH_SWAP_LIMIT_MB (default 3072), or free disk drops under 5 GB.
set -u

cd "$(dirname "$0")/.."
REPO="$PWD"
swift build -q || exit 1
BIN="$(swift build --show-bin-path)/turnstile"

FACTOR="${BENCH_FACTOR:-1.3}"
CAP="${BENCH_CAP:-240}"
AGENTS=3
LANES_PER_AGENT=2
JOBS_PER_LANE=2
TARGET_SECONDS="${BENCH_JOB_SECONDS:-6}"

OUT="$REPO/.build/bench/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"
T="$(mktemp -d /tmp/turnstile-bench.XXXXXX)"
mkdir -p "$T/bin" "$T/config"

now() { perl -MTime::HiRes=time -e 'printf "%.3f", time'; }
level() { /usr/sbin/sysctl -n kern.memorystatus_level; }
swap_used_mb() { /usr/sbin/sysctl -n vm.swapusage | sed -E 's/.*used = ([0-9.]+)M.*/\1/'; }
disk_free_gb() { df -g / | awk 'NR == 2 { print $4 }'; }

cat > "$T/job.py" <<'EOF'
import os, sys, time
mb, passes, kind, limit = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3], float(sys.argv[4])
started = time.monotonic()
# Random pages don't compress, and repeating a 1 MB block keeps allocation fast.
buf = bytearray(os.urandom(1 << 20)) * mb
total = 0
for _ in range(passes):
    for i in range(0, len(buf), 16384):
        total += buf[i]
elapsed = time.monotonic() - started
print(f"RESULT {kind} work={elapsed:.2f}")
if kind == "test" and elapsed > limit:
    print(f"FAIL timing assertion: took {elapsed:.1f}s, limit {limit:.1f}s", file=sys.stderr)
    sys.exit(1)
EOF

cat > "$T/bin/swift" <<'EOF'
#!/bin/bash
exec /usr/bin/python3 "$BENCH_DIR/job.py" "$BENCH_MB" "$BENCH_PASSES" "$1" "$BENCH_LIMIT"
EOF
chmod +x "$T/bin/swift"

PHYS_MB=$(( $(/usr/sbin/sysctl -n hw.memsize) / 1048576 ))
START_LEVEL=$(level)
FREE_MB=$(( PHYS_MB * START_LEVEL / 100 ))
LANES=$(( AGENTS * LANES_PER_AGENT ))
DEMAND_MB=$(/usr/bin/python3 -c "print(int($FACTOR * $FREE_MB))")
JOB_MB=$(( DEMAND_MB / LANES ))

cleanup() {
  for pid in $(jobs -p); do kill -KILL -- "-$pid" 2> /dev/null; done
  pkill -KILL -f "$T/job.py" 2> /dev/null
  TURNSTILE_HOME="$T/home" "$BIN" stop > /dev/null 2>&1
  rm -rf "$T"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# Calibrate on a real-sized job run alone: time one and four passes, then pick passes for TARGET_SECONDS.
# The timing assertion is relative to that solo run, so it holds on any machine.
solo() {
  BENCH_DIR="$T" BENCH_MB="$JOB_MB" BENCH_PASSES="$1" BENCH_LIMIT=1e9 "$T/bin/swift" build 2>&1 \
    | sed -nE 's/.*work=([0-9.]+).*/\1/p'
}
ONE=$(solo 1)
FOUR=$(solo 4)
PASSES=$(/usr/bin/python3 -c "per = max(0.01, ($FOUR - $ONE) / 3); print(max(1, int(1 + ($TARGET_SECONDS - $ONE) / per)))")
SOLO=$(solo "$PASSES")
LIMIT=$(/usr/bin/python3 -c "print(round(3 * $SOLO + 3, 1))")

echo "machine: $(/usr/sbin/sysctl -n machdep.cpu.brand_string), $(( PHYS_MB / 1024 )) GB, macOS $(sw_vers -productVersion)"
echo "start: ${START_LEVEL}% free (~$(( FREE_MB / 1024 )) GB); demand ${DEMAND_MB} MB over $LANES lanes, ${JOB_MB} MB per job"
echo "solo job ${SOLO}s ($PASSES passes); tests fail past ${LIMIT}s"

cat > "$OUT/meta.json" <<EOF
{"machine": "$(/usr/sbin/sysctl -n machdep.cpu.brand_string)", "cores": $(/usr/sbin/sysctl -n hw.ncpu), "physical_mb": $PHYS_MB,
 "macos": "$(sw_vers -productVersion)", "factor": $FACTOR, "cap_seconds": $CAP, "agents": $AGENTS,
 "lanes": $LANES, "jobs_per_lane": $JOBS_PER_LANE, "job_mb": $JOB_MB, "demand_mb": $DEMAND_MB,
 "start_level": $START_LEVEL, "passes": $PASSES, "solo_seconds": $SOLO, "test_limit_seconds": $LIMIT}
EOF

wait_for_recovery() {
  local target=$1 deadline=$(( $(date +%s) + 60 ))
  while [ "$(level)" -lt "$target" ] && [ "$(date +%s)" -lt "$deadline" ]; do sleep 2; done
}

# One lane: an agent running builds or tests back to back, each in its own worktree.
lane() {
  local arm=$1 lane=$2 kind=$3 j start end code
  mkdir -p "$T/work/$arm/$lane" && cd "$T/work/$arm/$lane" || return
  for j in $(seq "$JOBS_PER_LANE"); do
    start=$(now)
    echo "$arm $lane $j $kind $start" > "$T/current-$arm-$lane"
    swift "$kind" > "$T/$arm-$lane-$j.out" 2>&1; code=$?
    end=$(now)
    rm -f "$T/current-$arm-$lane"
    work=$(sed -nE 's/^RESULT .* work=([0-9.]+).*/\1/p' "$T/$arm-$lane-$j.out")
    echo "$arm $lane $j $kind $start $end $code ${work:--}" >> "$OUT/jobs.txt"
  done
}

run_arm() {
  local arm=$1 started aborted=0 pids=() pid reason=done t0 ended f swap0 swap
  echo "--- $arm"
  : > "$OUT/samples-$arm.txt"
  export BENCH_DIR="$T" BENCH_MB="$JOB_MB" BENCH_PASSES="$PASSES" BENCH_LIMIT="$LIMIT"
  export TURNSTILE_HOME="$T/home" TURNSTILE_CONFIG_DIR="$T/config" TURNSTILE_AGENT=1 PATH="$T/home/shims:$T/bin:/usr/bin:/bin"
  unset TURNSTILE_TOKEN TURNSTILE_MEMORY_LEVEL_FILE
  if [ "$arm" = ungated ]; then export TURNSTILE_DISABLE=1; else unset TURNSTILE_DISABLE; fi
  "$BIN" shims > /dev/null

  started=$(now)
  t0=$(date +%s)
  swap0=$(swap_used_mb)
  echo "$arm start $started" >> "$OUT/arms.txt"
  set -m  # each lane in its own process group, so a cap or abort takes its whole tree
  for n in $(seq 0 $(( LANES - 1 ))); do
    if [ $(( n % 2 )) = 0 ]; then kind=build; else kind=test; fi
    lane "$arm" "$n" "$kind" &
    pids+=($!)
  done
  set +m

  while :; do
    running=0
    for pid in "${pids[@]}"; do kill -0 "$pid" 2> /dev/null && running=1; done
    [ $running = 0 ] && break
    lv=$(level)
    swap=$(swap_used_mb)
    echo "$(now) $lv $swap" >> "$OUT/samples-$arm.txt"
    elapsed=$(( $(date +%s) - t0 ))
    swapped=$(/usr/bin/python3 -c "print(int($swap - $swap0))")
    if [ "$elapsed" -ge "$CAP" ] || [ "$lv" -lt 10 ] || [ "$swapped" -ge "${BENCH_SWAP_LIMIT_MB:-3072}" ] || [ "$(disk_free_gb)" -lt 5 ]; then
      [ "$elapsed" -ge "$CAP" ] && reason=cap || reason=watchdog
      echo "stopping $arm ($reason)"
      for pid in "${pids[@]}"; do kill -KILL -- "-$pid" 2> /dev/null; done
      pkill -KILL -f "$T/job.py" 2> /dev/null
      aborted=1
      break
    fi
    sleep 1
  done
  wait 2> /dev/null
  ended=$(now)
  # Jobs cut off by the cap or watchdog, so a stopped arm still says how far it got.
  for f in "$T"/current-"$arm"-*; do [ -f "$f" ] && echo "$(cat "$f") $ended stopped -" >> "$OUT/jobs.txt"; done
  rm -f "$T"/current-"$arm"-*
  echo "$arm end $ended $reason" >> "$OUT/arms.txt"
  [ "$arm" = gated ] && cp "$T/home/daemon.log" "$OUT/daemon.log" 2> /dev/null
  "$BIN" stop > /dev/null 2>&1
  unset TURNSTILE_DISABLE
  return $aborted
}

LOG_START="$(date '+%Y-%m-%d %H:%M:%S')"
# Gated first; an ungated arm waits for memory to recover to the same starting level.
run_arm gated
if [ "${BENCH_UNGATED:-0}" = 1 ]; then
  wait_for_recovery "$START_LEVEL"
  run_arm ungated
fi

# Jetsam kills anywhere on the machine during the run.
/usr/bin/log show --style compact --start "$LOG_START" \
  --predicate 'sender == "kernel" AND eventMessage CONTAINS "memorystatus" AND eventMessage CONTAINS "kill"' \
  2> /dev/null | grep -v '^Timestamp' > "$OUT/jetsam.txt"

/usr/bin/python3 - "$OUT" <<'EOF'
import json, os, statistics, sys
out = sys.argv[1]
meta = json.load(open(f"{out}/meta.json"))
arms = {}
for line in open(f"{out}/arms.txt"):
    parts = line.split()
    arms.setdefault(parts[0], {})[parts[1]] = float(parts[2])
    if parts[1] == "end": arms[parts[0]]["stopped"] = parts[3]
jobs = [l.split() for l in open(f"{out}/jobs.txt")] if os.path.exists(f"{out}/jobs.txt") else []
jetsam = [l for l in open(f"{out}/jetsam.txt") if l.strip()]

def jetsam_during(arm, idle):
    """Processes macOS killed during the arm: for memory pressure, or routine idle exits."""
    import datetime
    count = 0
    for l in jetsam:
        # One line per killed process names its pid; the other lines announce a reason.
        if "killing_" not in l: continue
        try:
            t = datetime.datetime.strptime(" ".join(l.split()[:2])[:23], "%Y-%m-%d %H:%M:%S.%f").timestamp()
        except ValueError:
            continue
        if not arms[arm]["start"] <= t <= arms[arm]["end"]: continue
        if ("idle-exit" in l) == idle: count += 1
    return count

results = {"meta": meta, "arms": {}}
planned = meta["lanes"] * meta["jobs_per_lane"]
for arm in ["ungated", "gated"]:
    if arm not in arms: continue
    rows = [j for j in jobs if j[0] == arm and j[6] != "stopped"]
    cut_off = [j for j in jobs if j[0] == arm and j[6] == "stopped"]
    done = [j for j in rows if j[6] == "0"]
    failed_tests = [j for j in rows if j[3] == "test" and j[6] == "1"]
    other_fail = [j for j in rows if j[6] not in ("0", "1") or (j[3] == "build" and j[6] != "0")]
    walls = [float(j[5]) - float(j[4]) for j in rows]
    works = [float(j[7]) for j in rows if j[7] != "-"]
    samples = [l.split() for l in open(f"{out}/samples-{arm}.txt")]
    levels = [int(s[1]) for s in samples]
    swaps = [float(s[2]) for s in samples]
    daemon = open(f"{out}/daemon.log").read() if arm == "gated" and os.path.exists(f"{out}/daemon.log") else ""
    results["arms"][arm] = {
        "wall_seconds": round(arms[arm]["end"] - arms[arm]["start"], 1),
        "stopped": arms[arm].get("stopped"),
        "jobs_planned": planned,
        "jobs_finished": len(rows),
        "jobs_ok": len(done),
        "test_timing_failures": len(failed_tests),
        "other_failures": len(other_fail),
        "job_wall_median": round(statistics.median(walls), 1) if walls else None,
        "job_wall_max": round(max(walls), 1) if walls else None,
        "job_work_median": round(statistics.median(works), 1) if works else None,
        "job_work_max": round(max(works), 1) if works else None,
        "min_memory_level": min(levels) if levels else None,
        "swap_start_mb": round(swaps[0]) if swaps else None,
        "swap_peak_mb": round(max(swaps)) if swaps else None,
        "swap_growth_mb": round(max(swaps) - swaps[0]) if swaps else None,
        "jetsam_kills": jetsam_during(arm, idle=False),
        "turnstile_pauses": daemon.count(" paused at "),
        "turnstile_kills": daemon.count(": killed "),
    }
json.dump(results, open(f"{out}/results.json", "w"), indent=2)

a = results["arms"]
labels = [
    ("Arm wall time (s)", "wall_seconds"), ("Stopped by", "stopped"),
    ("Jobs finished / planned", None), ("Jobs passed", "jobs_ok"),
    ("Tests failing their timing assertion", "test_timing_failures"), ("Other failures", "other_failures"),
    ("Job time incl. queue, median / max (s)", ("job_wall_median", "job_wall_max")),
    ("Job run time, median / max (s)", ("job_work_median", "job_work_max")),
    ("Min memory free (%)", "min_memory_level"), ("Swap growth (MB)", "swap_growth_mb"),
    ("Jetsam kills (machine-wide)", "jetsam_kills"), ("turnstile pauses / kills", ("turnstile_pauses", "turnstile_kills")),
]
arms_order = [x for x in ["ungated", "gated"] if x in a]
md = ["| | " + " | ".join(arms_order) + " |", "| --- |" + " --- |" * len(arms_order)]
for label, key in labels:
    cells = []
    for arm in arms_order:
        r = a[arm]
        if key is None: cells.append(f"{r['jobs_finished']} / {r['jobs_planned']}")
        elif isinstance(key, tuple): cells.append(" / ".join(str(r[k]) for k in key))
        else: cells.append(str(r[key]))
    md.append(f"| {label} | " + " | ".join(cells) + " |")
open(f"{out}/results.md", "w").write("\n".join(md) + "\n")
print("\n".join(md))
print(f"\nresults in {out}")
EOF
