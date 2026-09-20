#!/bin/bash
# Soak: real toolchains running through turnstile while memory pressure forces an automatic pause.
# Issue #20: the pause has never fired in real use, so we don't know whether stopping a real toolchain is safe.
#
# Each workload runs twice: a baseline alone with no pressure, then a soak where two copies run together,
# pressure is applied, the newer copy is paused, held, and released. Every check from #20 is recorded per run.
#
#   ./scripts/pressure-soak.sh                        # every workload it can build, fake level file
#   ./scripts/pressure-soak.sh swift-build vitest     # only these
#   ./scripts/pressure-soak.sh --driver alloc         # real allocation; needs a machine you can afford to lose
#   ./scripts/pressure-soak.sh --list                 # what it would run, and why anything is skipped
#
# Drivers:
#   fake   writes TURNSTILE_MEMORY_LEVEL_FILE. No machine risk, and the pause fires on a schedule, so it answers
#          risks 3-6 (shared escapees, wall-clock timeouts, starvation, worker races) but not 1-2.
#   alloc  `memory_pressure -p` allocates until the machine really is short. Answers risks 1-2 as well:
#          whether the threshold is reachable, and whether a pause frees anything. A watchdog aborts on swap growth.
#
# Results in .build/soak/<timestamp>/: results.md, results.json, per-run status samples, and the daemon log.
set -u

cd "$(dirname "$0")/.."
REPO="$PWD"

DRIVER=fake
LIST=0
SELECTED=()
for arg in "$@"; do
  case "$arg" in
    --driver=*) DRIVER="${arg#*=}" ;;
    --driver) DRIVER=next ;;
    --list) LIST=1 ;;
    -*) echo "unknown option $arg" >&2; exit 2 ;;
    *) if [ "$DRIVER" = next ]; then DRIVER="$arg"; else SELECTED+=("$arg"); fi ;;
  esac
done
case "$DRIVER" in fake|alloc) ;; *) echo "driver must be fake or alloc" >&2; exit 2 ;; esac

PAUSE_BELOW=8
RESUME_ABOVE=20
ALLOC_TARGET="${SOAK_ALLOC_PERCENT:-6}"
# A workload shorter than this leaves no room to pause, hold, and resume inside one run.
MIN_BASELINE="${SOAK_MIN_BASELINE:-8}"
# Long enough to see a job stay paused past a runner's 5s per-test timeout, and to probe both pressure bands.
HOLD="${SOAK_HOLD_SECONDS:-12}"
[ "$HOLD" -lt 9 ] && HOLD=9
# The pause must land within one daemon tick (1s) plus its 3s floor between pressure actions.
PAUSE_BUDGET=5
SWAP_LIMIT_MB="${SOAK_SWAP_LIMIT_MB:-3072}"

OUT="$REPO/.build/soak/$(date +%Y%m%d-%H%M%S)"
# Resolved, because the daemon reports each job's real cwd and the soak matches jobs by it.
T="$(cd "$(mktemp -d /tmp/turnstile-soak.XXXXXX)" && pwd -P)"
# Any shims already on PATH belong to the machine's own daemon; this run uses its own throwaway home.
PATH="$(echo "$PATH" | tr ':' '\n' | grep -v '\.turnstile/shims' | paste -sd: -)"
export PATH
export TURNSTILE_HOME="$T/home" TURNSTILE_CONFIG_DIR="$T/config" TURNSTILE_AGENT=1
export TURNSTILE_MEMORY_LEVEL_FILE="$T/level"
unset TURNSTILE_TOKEN TURNSTILE_DISABLE
mkdir -p "$OUT" "$T/config" "$T/work" "$T/fixtures"

level() { /usr/sbin/sysctl -n kern.memorystatus_level; }
pressure_level() { /usr/sbin/sysctl -n kern.memorystatus_vm_pressure_level; }
swap_used_mb() { /usr/sbin/sysctl -n vm.swapusage | sed -E 's/.*used = ([0-9.]+)M.*/\1/'; }
now() { perl -MTime::HiRes=time -e 'printf "%.3f", time'; }
json_escape() { /usr/bin/python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'; }

# The level turnstile sees. The fake driver writes the file; the alloc driver makes it follow the real one.
set_level() { echo "$1" > "$T/level"; }
set_level 90

swift build -q || exit 1
BIN="$(swift build --show-bin-path)/turnstile"
export PATH="$TURNSTILE_HOME/shims:$PATH"
"$BIN" shims > /dev/null

# Four slots so the holder, two copies, and the starvation probe all fit, leaving memory the only gate.
cat > "$T/config/config.json" <<EOF
{"concurrency": {"compile": 4, "test": 4}, "pauseBelow": $PAUSE_BELOW, "resumeAbove": $RESUME_ABOVE}
EOF

ALLOC_PID=
cleanup() {
  [ -n "$ALLOC_PID" ] && kill "$ALLOC_PID" 2> /dev/null
  pkill -f "$T/work" 2> /dev/null
  "$BIN" stop > /dev/null 2>&1
  # Anything still writing into the tree would leave it behind, so give it a moment, then insist.
  sleep 1
  pkill -9 -f "$T/work" 2> /dev/null
  rm -rf "$T" 2> /dev/null || { sleep 2; rm -rf "$T" 2> /dev/null; }
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# MARK: fixtures
# Each fixture is a project directory the soak copies per run, so two copies never merge as the same fingerprint.

swift_files="${SOAK_SWIFT_FILES:-60}"
make_swift_package() {
  local dir=$1 i
  mkdir -p "$dir/Sources/Soak" "$dir/Tests/SoakTests"
  cat > "$dir/Package.swift" <<'EOF'
// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "Soak",
    targets: [.target(name: "Soak"), .testTarget(name: "SoakTests", dependencies: ["Soak"])]
)
EOF
  for i in $(seq 1 "$swift_files"); do
    cat > "$dir/Sources/Soak/Part$i.swift" <<EOF
public struct Part$i: Equatable, Codable {
    public var name: String
    public var values: [Int]
    public init(name: String = "part$i", values: [Int] = Array(0..<8)) {
        self.name = name
        self.values = values
    }
    public func described() -> String {
        values.enumerated().map { "\(\$0.offset):\(\$0.element):\(name)" }.joined(separator: ",")
    }
    public static func combine(_ items: [Part$i]) -> [String: [Int]] {
        Dictionary(uniqueKeysWithValues: items.enumerated().map { ("\(\$0.offset)-\(\$0.element.name)", \$0.element.values) })
    }
}
EOF
  done
  # Stands in for any test with a wall-clock deadline: a heartbeat running the length of the suite that
  # checks no step stretched past 5s. A pause lands inside it wherever it falls, which is risk 4.
  cat > "$dir/Tests/SoakTests/SoakTests.swift" <<EOF
import XCTest
@testable import Soak

final class SoakTests: XCTestCase {
    func testNoStepStretchesPastItsDeadline() {
        var worst: TimeInterval = 0
        for _ in 0..<${SOAK_HEARTBEAT_STEPS:-30} {
            let started = Date()
            Thread.sleep(forTimeInterval: 0.5)
            worst = max(worst, Date().timeIntervalSince(started))
        }
        if worst >= 5 { print("TIMEOUT took \\(worst)s") }
        XCTAssertLessThan(worst, 5)
    }

    func testWork() {
        for _ in 0..<200 { XCTAssertEqual(Part1.combine([Part1(), Part1(name: "b")]).count, 2) }
    }
}
EOF
}

make_node_project() {
  local dir=$1 i
  mkdir -p "$dir/src" "$dir/tests"
  cat > "$dir/package.json" <<'EOF'
{"name": "soak", "private": true, "type": "module",
 "devDependencies": {"vitest": "^2.1.8", "jest": "^29.7.0", "typescript": "^5.7.2"}}
EOF
  cat > "$dir/tsconfig.json" <<'EOF'
{"compilerOptions": {"target": "es2022", "module": "es2022", "moduleResolution": "bundler", "strict": true,
 "noEmit": true, "skipLibCheck": false}, "include": ["src"]}
EOF
  for i in $(seq 1 "${SOAK_TS_FILES:-400}"); do
    cat > "$dir/src/part$i.ts" <<EOF
export interface Part${i} { name: string; values: number[]; nested: Record<string, Part${i}[]> }
export const make$i = (name = "part$i"): Part$i => ({ name, values: [...Array(16).keys()], nested: {} })
export const describe$i = (p: Part$i): string => p.values.map((v, i) => \`\${i}:\${v}:\${p.name}\`).join(",")
export const combine${i} = (items: Part${i}[]): Record<string, number[]> =>
  Object.fromEntries(items.map((p, i) => [\`\${i}-\${p.name}\`, p.values]))
EOF
  done
  # vitest would otherwise collect the jest files too, and fail on their globals.
  cat > "$dir/vitest.config.js" <<'EOF'
export default { test: { include: ["tests/**/*.test.js"] } }
EOF
  cat > "$dir/jest.config.cjs" <<'EOF'
module.exports = { testMatch: ["**/jest-tests/**/*.test.cjs"], maxWorkers: 2 }
EOF
  mkdir -p "$dir/jest-tests"
  # Stands in for any test with a wall-clock deadline: a heartbeat that runs for the whole suite and checks
  # that no step stretched past 5s. A pause lands inside it wherever it falls, which is risk 4.
  cat > "$dir/tests/heartbeat.test.js" <<EOF
import { test, expect } from "vitest"
test("no step stretches past its deadline", async () => {
  let worst = 0
  for (let i = 0; i < ${SOAK_HEARTBEAT_STEPS:-30}; i++) {
    const started = Date.now()
    await new Promise((r) => setTimeout(r, 500))
    worst = Math.max(worst, Date.now() - started)
  }
  if (worst >= 5000) console.log(\`TIMEOUT took \${worst}ms\`)
  expect(worst).toBeLessThan(5000)
}, 300000)
EOF
  sed 's/^import .*$//' "$dir/tests/heartbeat.test.js" > "$dir/jest-tests/heartbeat.test.cjs"
  # Enough files to keep several workers busy for long enough to pause one of them mid-test.
  for i in $(seq 1 "${SOAK_TEST_FILES:-6}"); do
    cat > "$dir/tests/work$i.test.js" <<EOF
import { test, expect } from "vitest"
test("work $i", () => {
  let total = 0
  for (let j = 0; j < ${SOAK_TEST_LOOP:-2e9}; j++) total += j % 7
  expect(total).toBeGreaterThan(0)
})
EOF
    sed 's/^import .*$//' "$dir/tests/work$i.test.js" > "$dir/jest-tests/work$i.test.cjs"
  done
}

# MARK: workloads
# name|fixture|command. The command runs inside a copy of the fixture, through the shims.

WORKLOADS=()
SKIPPED=()
add_workload() { WORKLOADS+=("$1|$2|$3"); }
skip_workload() { SKIPPED+=("$1|$2"); }

have() { command -v "$1" > /dev/null 2>&1; }
# Building a fixture is slow, so only build one some selected workload needs.
wants() {
  [ ${#SELECTED[@]} -eq 0 ] && return 0
  local want name
  for want in "${SELECTED[@]}"; do for name in "$@"; do [ "$want" = "$name" ] && return 0; done; done
  return 1
}

make_swift_package "$T/fixtures/swiftpkg"
# The starvation probe (risk 5) has to be small, since the question is whether headroom still admits small jobs.
SOAK_SWIFT_FILES=1 swift_files=1 make_swift_package "$T/fixtures/probe"
# A third job that simply outlasts the run. Without it the other copy finishes mid-hold, `running` goes empty,
# and the daemon resumes the paused job however low the level is, which cuts every pause short.
mkdir -p "$T/fixtures/holder"
printf 'hold:\n\t@sleep $(SOAK_HOLD_TOTAL)\n' > "$T/fixtures/holder/Makefile"
add_workload swift-build swiftpkg "swift build"
add_workload swift-test swiftpkg "swift test"
if [ -d /Applications/Xcode.app ] && have xcodebuild; then
  # Its own derived data, so the second copy compiles from cold rather than reusing the first's modules.
  add_workload xcodebuild swiftpkg "xcodebuild -scheme Soak-Package -destination platform=macOS -derivedDataPath .dd build"
else
  skip_workload xcodebuild "Xcode is not installed"
fi

NODE_READY=0
if ! have npm; then
  for w in vitest jest tsc; do skip_workload "$w" "npm is not installed"; done
elif [ "$LIST" = 1 ] || ! wants vitest jest tsc; then
  NODE_READY=1  # nothing to install, because nothing selected needs it
elif make_node_project "$T/fixtures/node" &&
     { echo "installing node devDependencies for the vitest, jest, and tsc workloads..."
       (cd "$T/fixtures/node" && npm install --silent --no-audit --no-fund > "$T/npm-install.log" 2>&1); }; then
  NODE_READY=1
else
  cp "$T/npm-install.log" "$OUT/" 2> /dev/null
  for w in vitest jest tsc; do skip_workload "$w" "npm install failed, see npm-install.log"; done
fi
if [ "$NODE_READY" = 1 ]; then
  add_workload vitest node "npx vitest run"
  add_workload jest node "npx jest"
  add_workload tsc node "npx tsc -p ."
fi

for tool in cargo gradle; do
  have "$tool" && skip_workload "$tool" "no $tool fixture yet" || skip_workload "$tool" "$tool is not installed"
done

if [ ${#SELECTED[@]} -gt 0 ]; then
  filtered=()
  for entry in "${WORKLOADS[@]}"; do
    for want in "${SELECTED[@]}"; do [ "${entry%%|*}" = "$want" ] && filtered+=("$entry"); done
  done
  WORKLOADS=("${filtered[@]:-}")
  [ -z "${WORKLOADS[0]}" ] && WORKLOADS=()
fi

if [ "$LIST" = 1 ]; then
  echo "workloads:"
  for entry in "${WORKLOADS[@]}"; do IFS='|' read -r name _ cmd <<< "$entry"; echo "  $name  ($cmd)"; done
  echo "skipped:"
  for entry in "${SKIPPED[@]}"; do IFS='|' read -r name why <<< "$entry"; echo "  $name  ($why)"; done
  exit 0
fi
[ ${#WORKLOADS[@]} -eq 0 ] && { echo "nothing to run" >&2; exit 1; }

# MARK: pressure drivers

start_pressure() {
  case "$DRIVER" in
    fake) set_level $(( PAUSE_BELOW - 3 )) ;;
    alloc) /usr/bin/memory_pressure -p "$ALLOC_TARGET" > "$T/memory_pressure.log" 2>&1 & ALLOC_PID=$! ;;
  esac
}

stop_pressure() {
  case "$DRIVER" in
    fake) set_level $(( RESUME_ABOVE + 40 )) ;;
    alloc) [ -n "$ALLOC_PID" ] && kill "$ALLOC_PID" 2> /dev/null; ALLOC_PID= ;;
  esac
}

# Between bands: pressure has eased but not past resumeAbove, which is where a paused job can starve (risk 5).
ease_pressure() {
  case "$DRIVER" in
    fake) set_level $(( (PAUSE_BELOW + RESUME_ABOVE) / 2 )) ;;
    alloc) : ;;
  esac
}

# The alloc driver leaves turnstile reading the real level, so the file has to track it.
mirror_level() { [ "$DRIVER" = alloc ] && set_level "$(level)"; return 0; }

# MARK: checks

# Compacted, so each sample is one line of JSONL.
status_json() {
  "$BIN" status --json 2> /dev/null \
    | /usr/bin/python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin), separators=(",", ":")))' 2> /dev/null \
    || echo null
}

# Fields of the running job whose cwd is under $1, via python so a missing daemon is just an empty answer.
job_field() {
  local dir=$1 field=$2
  status_json | /usr/bin/python3 -c '
import json, sys
dir, field = sys.argv[1], sys.argv[2]
try: s = json.load(sys.stdin)
except Exception: print(""); raise SystemExit
for job in s.get("running", []) + s.get("queued", []):
    if job.get("cwd", "").startswith(dir):
        v = job.get(field)
        print("" if v is None else (" ".join(str(x) for x in v) if isinstance(v, list) else v))
        raise SystemExit
print("")
' "$dir" "$field"
}

union() { echo "$1 $2" | tr ' ' '\n' | sort -u | tr '\n' ' ' | sed -E 's/^ +| +$//g'; }
# What every process in the tree was doing, so a process that ignored the pause can be identified, not just counted.
trace_tree() {
  local file=$1 label=$2 pids=$3
  { echo "# $(now) $label"; [ -n "$pids" ] && ps -o pid=,ppid=,state=,wq=,comm= -p ${pids// /,} 2> /dev/null; } >> "$file"
}
intersect() {
  comm -12 <(echo "$1" | tr ' ' '\n' | sort -u) <(echo "$2" | tr ' ' '\n' | sort -u) \
    | tr '\n' ' ' | sed -E 's/^ +| +$//g'
}

# Every process in $1 that is not stopped, so an empty answer means the whole tree is in state T.
not_stopped() {
  local pid state states=()
  for pid in $1; do
    state=$(ps -o state= -p "$pid" 2> /dev/null | tr -d ' ')
    [ -n "$state" ] && [ "${state:0:1}" != "T" ] && states+=("$pid:$state")
  done
  echo "${states[*]:-}"
}

# The opposite: processes of the *other* job that a pause stopped, which should be none (risk 3).
stopped_among() {
  local pid state out=()
  for pid in $1; do
    state=$(ps -o state= -p "$pid" 2> /dev/null | tr -d ' ')
    [ -n "$state" ] && [ "${state:0:1}" = "T" ] && out+=("$pid")
  done
  echo "${out[*]:-}"
}

# MARK: run

: > "$OUT/runs.txt"
PHYS_MB=$(( $(/usr/sbin/sysctl -n hw.memsize) / 1048576 ))
echo "machine: $(/usr/sbin/sysctl -n machdep.cpu.brand_string), $(( PHYS_MB / 1024 )) GB, macOS $(sw_vers -productVersion)"
echo "driver: $DRIVER, pauseBelow ${PAUSE_BELOW}%, resumeAbove ${RESUME_ABOVE}%, hold ${HOLD}s"
cat > "$OUT/meta.json" <<EOF
{"machine": "$(/usr/sbin/sysctl -n machdep.cpu.brand_string)", "cores": $(/usr/sbin/sysctl -n hw.ncpu),
 "physical_mb": $PHYS_MB, "macos": "$(sw_vers -productVersion)", "turnstile": "$("$BIN" --version 2> /dev/null | tr -d '\n')",
 "driver": "$DRIVER", "pause_below": $PAUSE_BELOW, "resume_above": $RESUME_ABOVE, "hold_seconds": $HOLD,
 "started": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
 "skipped": [$(for e in "${SKIPPED[@]:-}"; do [ -n "$e" ] && printf '{"workload": "%s", "why": "%s"},' "${e%%|*}" "${e#*|}"; done | sed 's/,$//')]}
EOF

# One copy of a fixture, ready to run.
copy_fixture() {
  local fixture=$1 dest=$2
  rm -rf "$dest"
  mkdir -p "$(dirname "$dest")"
  cp -R "$T/fixtures/$fixture" "$dest"
}

baseline() {
  local name=$1 fixture=$2 cmd=$3 dir="$T/work/$name/base" start end code
  copy_fixture "$fixture" "$dir"
  set_level 90
  start=$(now)
  (cd "$dir" && eval "$cmd") > "$OUT/$name-baseline.out" 2>&1
  code=$?
  end=$(now)
  BASE_CODE=$code
  BASE_SECONDS=$(/usr/bin/python3 -c "print(round($end - $start, 1))")
}

# A sample a second for the whole run: what the kernel says, and what turnstile says about it.
sampler() {
  local file=$1
  while :; do
    mirror_level
    echo "{\"t\": $(now), \"level\": $(level), \"pressure\": $(pressure_level), \"swap_mb\": $(swap_used_mb), \"status\": $(status_json)}" >> "$file"
    sleep 1
  done
}

# The alloc driver really does take the machine's memory, so it gives up rather than thrash.
over_swap_limit() {
  [ "$DRIVER" = alloc ] || return 1
  /usr/bin/python3 -c "import sys; sys.exit(0 if $(swap_used_mb) - $1 >= $SWAP_LIMIT_MB else 1)"
}

# Waits until $2 reports pausedBy=$3 (or stops doing so, with `until`), or the deadline passes.
await_pause_state() {
  local want=$1 dir=$2 pid=$3 deadline=$(( $(date +%s) + $4 )) swap0=$5
  while [ "$(date +%s)" -lt "$deadline" ]; do
    [ "$(job_field "$dir" pausedBy)" = "$want" ] && { now; return 0; }
    kill -0 "$pid" 2> /dev/null || return 1
    over_swap_limit "$swap0" && { echo "swap grew past ${SWAP_LIMIT_MB}MB" > "$T/aborted"; return 1; }
    sleep 1
  done
  return 1
}

# The soak proper: an older copy holds a slot, a newer copy is the one pressure should pause.
soak_run() {
  local name=$1 fixture=$2 cmd=$3
  local older="$T/work/$name/older" newer="$T/work/$name/newer" probe="$T/work/$name/probe"
  local holder="$T/work/$name/holder"
  copy_fixture "$fixture" "$older"
  copy_fixture "$fixture" "$newer"
  copy_fixture probe "$probe"
  copy_fixture holder "$holder"
  set_level 90
  : > "$OUT/status-$name.jsonl"
  rm -f "$T/aborted"

  local holder_pid older_pid newer_pid probe_pid= sampler_pid
  sampler "$OUT/status-$name.jsonl" & sampler_pid=$!
  # The oldest job, so never the one a pause picks, and long enough to outlast the whole run.
  SOAK_HOLD_TOTAL=$(/usr/bin/python3 -c "print(int($BASE_SECONDS * 3 + $HOLD + 90))") \
    bash -c "cd '$holder' && make hold" > "$OUT/$name-holder.out" 2>&1 &
  holder_pid=$!
  sleep 2
  # A person's job, so the daemon never pauses it: the pause under test then has a real toolchain still
  # running beside it, which is what makes a shared build server (risk 3) or a starved slot (risk 5) visible.
  TURNSTILE_AGENT=0 bash -c "cd '$older' && $cmd" > "$OUT/$name-older.out" 2>&1 &
  older_pid=$!
  sleep 2
  (cd "$newer" && eval "$cmd") > "$OUT/$name-newer.out" 2>&1 &
  newer_pid=$!

  # Wait for both to be running before applying pressure, so the pause has a real choice to make.
  local deadline=$(( $(date +%s) + 60 ))
  while [ "$(job_field "$newer" state)" != running ] && [ "$(date +%s)" -lt "$deadline" ]; do
    kill -0 "$newer_pid" 2> /dev/null || break
    sleep 0.5
  done

  # Let the job get properly under way first: a toolchain paused in its first second has no children,
  # no build server, and no test in flight, which is the easy case rather than the one #20 asks about.
  sleep "$(/usr/bin/python3 -c "print(round(min(30, max(2, $BASE_SECONDS * ${SOAK_SETTLE_FRACTION:-0.4})), 1))")"

  local tree_before swap_before level_before pressure_before
  tree_before=$(job_field "$newer" tree)
  swap_before=$(swap_used_mb)
  level_before=$(level)
  pressure_before=$(pressure_level)

  local pause_asked pause_seen stopped_ok=na overlap="" other_stopped=""
  pause_asked=$(now)
  start_pressure
  pause_seen=$(await_pause_state memory "$newer" "$newer_pid" 30 "$swap_before") || pause_seen=

  local pause_delay=- tree_paused="" escapees="" older_tree=""
  if [ -n "$pause_seen" ]; then
    pause_delay=$(/usr/bin/python3 -c "print(round($pause_seen - $pause_asked, 1))")

    # Risk 5: can a small job still be admitted while one is paused, at the pause level and between bands?
    (cd "$probe" && swift build) > "$OUT/$name-probe.out" 2>&1 &
    probe_pid=$!

    # Every second of the hold: the union of the tree, anything in it still running, and anything of the
    # other job's that this pause stopped. One snapshot would miss a child spawned just as the stop landed.
    local elapsed=0 offenders="" tree_now older_now
    while [ "$elapsed" -lt "$HOLD" ]; do
      # The pause can end before the hold does: once the other job finishes, nothing is running, so the
      # daemon resumes this one whatever the level says. Anything after that isn't a pause being ignored.
      if [ "$(job_field "$newer" pausedBy)" != memory ]; then
        UNPAUSED_AT=$elapsed
        UNPAUSED_WITH_OTHER=$([ -n "$(job_field "$older" state)" ] && echo "other job still running" || echo "other job gone")
        break
      fi
      tree_now=$(job_field "$newer" tree)
      older_now=$(job_field "$older" tree)
      tree_paused=$(union "$tree_paused" "$tree_now")
      escapees=$(union "$escapees" "$(job_field "$newer" escapees)")
      older_tree=$(union "$older_tree" "$older_now")
      offenders="$offenders $(not_stopped "$tree_now")"
      # Only collateral damage counts here: the daemon keeps pausing until one job runs, so the other copy
      # being stopped in its own right is the policy working, not a shared process caught by this pause.
      [ -z "$(job_field "$older" pausedBy)" ] && other_stopped=$(union "$other_stopped" "$(stopped_among "$older_now")")
      trace_tree "$OUT/tree-$name.txt" "paused +${elapsed}s" "$tree_now"
      elapsed=$(( elapsed + 1 ))
      case "$elapsed" in
        3) PROBE_AT_PAUSE=$(job_field "$probe" state); ease_pressure ;;
        7) PROBE_BETWEEN=$(job_field "$probe" state)
           # Why it waited, if it did: a slot, or memory. Whether a paused job's memory gets handed to a new
           # job depends on how much is already committed, so the reason matters as much as the state.
           PROBE_WAITING=$(job_field "$probe" waiting) ;;
      esac
      sleep 1
    done
    # Risk 3: processes the two jobs share, which a pause of one stops for both.
    overlap=$(intersect "$tree_paused" "$older_tree")
    # `pid(xN)` for each process still running while the job was paused, N being how many seconds.
    # One second is the known window before the next tick stops a child spawned just as the pause landed.
    stopped_ok=$(echo "$offenders" | tr ' ' '\n' | grep -v '^$' | cut -d: -f1 | sort | uniq -c \
      | awk '{ printf "%s(x%s) ", $2, $1 }' | sed -E 's/ +$//')
    [ -z "$stopped_ok" ] && stopped_ok=ok
    [ -n "$probe_pid" ] && kill "$probe_pid" 2> /dev/null
  fi
  local swap_after level_paused
  swap_after=$(swap_used_mb)
  level_paused=$(level)

  stop_pressure
  local resume_seen
  resume_seen=$(await_pause_state "" "$newer" "$newer_pid" 90 "$swap_before") || resume_seen=

  wait "$newer_pid"; NEWER_CODE=$?
  wait "$older_pid"; OLDER_CODE=$?
  for pid in $probe_pid $holder_pid; do kill "$pid" 2> /dev/null; wait "$pid" 2> /dev/null; done
  kill "$sampler_pid" 2> /dev/null
  wait "$sampler_pid" 2> /dev/null

  PAUSE_DELAY=$pause_delay
  PAUSE_FIRED=$([ -n "$pause_seen" ] && echo yes || echo no)
  RESUME_FIRED=$([ -n "$resume_seen" ] && echo yes || echo no)
  TREE_BEFORE=$(echo "$tree_before" | wc -w | tr -d ' ')
  TREE_SIZE=$(echo "$tree_paused" | wc -w | tr -d ' ')
  ESCAPEES=$(echo "$escapees" | wc -w | tr -d ' ')
  ALL_STOPPED=$stopped_ok
  SHARED_WITH_OLDER=$(echo "$overlap" | wc -w | tr -d ' ')
  OTHER_JOB_STOPPED=${other_stopped:-none}
  LEVEL_BEFORE=$level_before
  LEVEL_PAUSED=$level_paused
  PRESSURE_BEFORE=$pressure_before
  SWAP_DELTA=$(/usr/bin/python3 -c "print(round($swap_after - $swap_before))")
}

# Runner noise that means a worker was treated as hung or crashed while stopped (risk 6).
worker_trouble() {
  grep -ciE "worker (process |thread )?(has failed|exited|encountered|crashed|is unresponsive)|terminating worker|child process (exited|terminated)|lost connection to" "$1" 2> /dev/null | tr -d ' '
}
# A wall-clock deadline that a pause blew through (risk 4). The exit code is the primary signal; this says why.
timeout_trouble() {
  grep -ciE "timed out|exceeded timeout|test timeout of|hook timed out|TIMEOUT took" "$1" 2> /dev/null | tr -d ' '
}

# One tab-separated row per run. The reader in results.py names these columns, in this order.
row() { local IFS=$'\t'; echo "$*" >> "$OUT/runs.txt"; }

for entry in "${WORKLOADS[@]}"; do
  IFS='|' read -r name fixture cmd <<< "$entry"
  echo "--- $name"
  PROBE_AT_PAUSE=- PROBE_BETWEEN=- PROBE_WAITING=- UNPAUSED_AT=- UNPAUSED_WITH_OTHER=-
  baseline "$name" "$fixture" "$cmd"
  echo "    baseline: exit $BASE_CODE in ${BASE_SECONDS}s"
  if /usr/bin/python3 -c "import sys; sys.exit(0 if $BASE_SECONDS < $MIN_BASELINE else 1)"; then
    echo "    skipped: baseline is under ${MIN_BASELINE}s, too short to pause and resume inside one run"
    row "$name" "too short to soak" "$BASE_CODE" "$BASE_SECONDS"
    continue
  fi
  soak_run "$name" "$fixture" "$cmd"
  row "$name" "$(cat "$T/aborted" 2> /dev/null || echo ran)" "$BASE_CODE" "$BASE_SECONDS" \
    "$PAUSE_FIRED" "$PAUSE_DELAY" "$RESUME_FIRED" "$NEWER_CODE" "$OLDER_CODE" \
    "$TREE_BEFORE" "$TREE_SIZE" "$ESCAPEES" "$ALL_STOPPED" "$SHARED_WITH_OLDER" "$OTHER_JOB_STOPPED" \
    "$(timeout_trouble "$OUT/$name-baseline.out")" "$(timeout_trouble "$OUT/$name-newer.out")" \
    "$(worker_trouble "$OUT/$name-baseline.out")" "$(worker_trouble "$OUT/$name-newer.out")" \
    "$PROBE_AT_PAUSE" "$PROBE_BETWEEN" "$LEVEL_BEFORE" "$LEVEL_PAUSED" "$PRESSURE_BEFORE" "$SWAP_DELTA" \
    "$UNPAUSED_AT" "$UNPAUSED_WITH_OTHER" "${PROBE_WAITING:--}"
  echo "    pause $PAUSE_FIRED (+${PAUSE_DELAY}s), resume $RESUME_FIRED, exit $NEWER_CODE vs baseline $BASE_CODE"
done

cp "$TURNSTILE_HOME/daemon.log" "$OUT/daemon.log" 2> /dev/null
"$BIN" stop > /dev/null 2>&1

/usr/bin/python3 - "$OUT" "$PAUSE_BUDGET" <<'EOF'
import json, os, sys
out, budget = sys.argv[1], float(sys.argv[2])
meta = json.load(open(f"{out}/meta.json"))
fields = ["workload", "status", "baseline_exit", "baseline_seconds", "pause_fired", "pause_delay_seconds",
          "resume_fired", "soak_exit", "older_exit", "tree_before", "tree_at_pause", "escapees",
          "all_stopped", "shared_pids_with_other_job", "other_job_processes_stopped",
          "baseline_timeout_lines", "soak_timeout_lines", "baseline_worker_lines", "soak_worker_lines",
          "probe_state_at_pause", "probe_state_between_bands", "level_before", "level_at_pause",
          "kernel_pressure_before", "swap_growth_mb", "unpaused_after_seconds", "unpaused_because",
          "probe_waiting_for"]
runs = []
for line in open(f"{out}/runs.txt"):
    parts = line.rstrip("\n").split("\t")
    runs.append(dict(zip(fields, parts + ["-"] * (len(fields) - len(parts)))))

def verdict(r):
    if r["status"] != "ran": return r["status"]
    problems = []
    if r["pause_fired"] != "yes": problems.append("never paused")
    else:
        if r["pause_delay_seconds"] not in ("-", "") and float(r["pause_delay_seconds"]) > budget:
            problems.append(f"pause took {r['pause_delay_seconds']}s")
        # A process still running one second after the pause is the next tick catching up; longer is an escape.
        escaped = [p for p in r["all_stopped"].split() if p != "ok" and not p.endswith("(x1)")]
        if escaped: problems.append("kept running while paused: " + " ".join(escaped))
        if r["other_job_processes_stopped"] not in ("none", "", "-"):
            problems.append(f"stopped another job's pids: {r['other_job_processes_stopped']}")
        if r["resume_fired"] != "yes": problems.append("never resumed")
    if r["soak_exit"] != r["baseline_exit"]: problems.append(f"exit {r['soak_exit']} vs {r['baseline_exit']}")
    if int(r["soak_timeout_lines"] or 0) > int(r["baseline_timeout_lines"] or 0): problems.append("new timeout output")
    if int(r["soak_worker_lines"] or 0) > int(r["baseline_worker_lines"] or 0): problems.append("new worker errors")
    if r["probe_state_between_bands"] == "running": problems.append("admitted a job while paused")
    return "; ".join(problems) if problems else "clean"

for r in runs: r["verdict"] = verdict(r)
json.dump({"meta": meta, "runs": runs}, open(f"{out}/results.json", "w"), indent=2)

cols = [("Workload", "workload"), ("Baseline exit / s", ("baseline_exit", "baseline_seconds")),
        ("Paused", "pause_fired"), ("Delay (s)", "pause_delay_seconds"), ("Resumed", "resume_fired"),
        ("Soak exit", "soak_exit"), ("Tree at pause / escapees", ("tree_at_pause", "escapees")),
        ("Whole tree stopped", "all_stopped"), ("Other job's pids stopped", "other_job_processes_stopped"),
        ("New timeouts / worker errors", ("soak_timeout_lines", "soak_worker_lines")),
        ("Probe at pause / between", ("probe_state_at_pause", "probe_state_between_bands")),
        ("Probe waiting for", "probe_waiting_for"),
        ("Pause cut short (s)", ("unpaused_after_seconds", "unpaused_because")), ("Verdict", "verdict")]
md = ["| " + " | ".join(c[0] for c in cols) + " |", "|" + " --- |" * len(cols)]
for r in runs:
    cells = []
    for _, key in cols:
        cells.append(" / ".join(r[k] for k in key) if isinstance(key, tuple) else r[key])
    md.append("| " + " | ".join(cells) + " |")
md += ["", f"Driver `{meta['driver']}`, pauseBelow {meta['pause_below']}%, resumeAbove {meta['resume_above']}%, "
       f"held {meta['hold_seconds']}s, on {meta['machine']} with {meta['physical_mb'] // 1024} GB, "
       f"macOS {meta['macos']}, turnstile {meta['turnstile']}."]
if meta["driver"] == "fake":
    md += ["", "The fake driver moves the level turnstile reads, so it says nothing about whether the threshold is "
           "reachable (risk 1) or whether a pause frees memory (risk 2). Re-run with `--driver alloc` for those."]
skipped = meta.get("skipped", [])
if skipped:
    md += ["", "Not run: " + ", ".join(f"{s['workload']} ({s['why']})" for s in skipped) + "."]
open(f"{out}/results.md", "w").write("\n".join(md) + "\n")
print("\n".join(md))
print(f"\nresults in {out}")
EOF
