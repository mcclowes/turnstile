#!/bin/bash
# End-to-end checks against the real binary, using fake tools in a throwaway turnstile home.
set -u

cd "$(dirname "$0")/.."
swift build -q || exit 1
BIN="$(swift build --show-bin-path)/turnstile"

T="$(mktemp -d /tmp/turnstile-e2e.XXXXXX)"
export TURNSTILE_HOME="$T/home"
export TURNSTILE_CONFIG_DIR="$T/config"
export TURNSTILE_MEMORY_LEVEL_FILE="$T/level"
export TURNSTILE_AGENT=1
unset TURNSTILE_TOKEN TURNSTILE_DISABLE
mkdir -p "$T/bin" "$T/config" "$T/work"
echo 90 > "$T/level"
echo '{"concurrency": {"test": 1, "compile": 2}}' > "$T/config/config.json"

# A fake `swift`: logs each run, can sleep, fail, nest, or allocate memory.
cat > "$T/bin/swift" <<'EOF'
#!/bin/bash
echo "fake swift $*"
echo "run $$ $*" >> "$FAKE_RUNS"
[ -n "${FAKE_NESTED:-}" ] && [ "$1" = test ] && FAKE_NESTED= swift build nested
[ -n "${FAKE_ALLOC_MB:-}" ] && exec /usr/bin/python3 -c "import time; b = bytearray(${FAKE_ALLOC_MB} * 1024 * 1024); [b.__setitem__(i, 1) for i in range(0, len(b), 4096)]; time.sleep(30)"
sleep "${FAKE_SLEEP:-0}"
echo "fake swift done" >&2
exit "${FAKE_EXIT:-0}"
EOF
chmod +x "$T/bin/swift"
export FAKE_RUNS="$T/runs"
: > "$FAKE_RUNS"

PATH="$TURNSTILE_HOME/shims:$T/bin:/usr/bin:/bin"
"$BIN" shims > /dev/null
export PATH

failures=0
pass() { echo "ok   $1"; }
fail() { echo "FAIL $1"; failures=$((failures + 1)); }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }
runs() { grep -cE "^run [0-9]+ $1" "$FAKE_RUNS"; }
cleanup() { turnstile stop > /dev/null 2>&1; rm -rf "$T"; }
trap cleanup EXIT

cd "$T/work"

# Pass-through never touches the daemon.
out="$(swift --version 2>&1)"
check "quick verbs pass through" '[ "$out" = "fake swift --version
fake swift done" ] && [ ! -S "$TURNSTILE_HOME/turnstiled.sock" ]'

# Gated runs keep output and exit codes.
out="$(FAKE_EXIT=3 swift build 2>&1)"; code=$?
check "exit code propagates" '[ $code = 3 ]'
check "output is unchanged" '[ "$out" = "fake swift build
fake swift done" ]'
check "daemon started on demand" '[ -S "$TURNSTILE_HOME/turnstiled.sock" ]'

# Two tests with one test slot: the second waits and says why.
mkdir -p a b
(cd a && FAKE_SLEEP=2 swift test > "$T/a.out" 2>&1) &
sleep 0.5
start=$(date +%s)
(cd b && FAKE_SLEEP=1 swift test > "$T/b.out" 2>&1)
wait
elapsed=$(( $(date +%s) - start ))
check "second job waits for the slot" '[ $elapsed -ge 2 ]'
check "waiting is visible" 'grep -q "turnstile: waiting for a test slot (running: a swift test" "$T/b.out"'

# A nested call inside an admitted job passes through instead of deadlocking.
out="$(FAKE_NESTED=1 perl -e 'alarm shift; exec @ARGV' 10 swift test 2>&1)"; code=$?
check "nested calls don't deadlock" '[ $code = 0 ] && echo "$out" | grep -q "fake swift build nested"'

# Identical runs on identical trees merge.
mkdir -p repo && cd repo && git init -q && echo hi > file && git add file && git -c user.email=t@t -c user.name=t commit -qm init
before=$(runs test)
(FAKE_SLEEP=2 FAKE_EXIT=4 swift test > "$T/m1.out" 2>&1; echo $? > "$T/m1.code") &
sleep 0.7
FAKE_SLEEP=2 FAKE_EXIT=4 swift test > "$T/m2.out" 2>&1; echo $? > "$T/m2.code"
wait
check "duplicate run joins the one in progress" '[ $(( $(runs test) - before )) = 1 ] && grep -q "joining an identical swift test" "$T/m2.out"'
check "joiner replays output and exit code" 'grep -q "fake swift test" "$T/m2.out" && [ "$(cat "$T/m2.code")" = 4 ] && [ "$(cat "$T/m1.code")" = 4 ]'

# A newer request from the same worktree replaces its queued one.
before=$(runs test)
(cd ../a && FAKE_SLEEP=2 swift test > /dev/null 2>&1) &
sleep 0.5
(FAKE_SLEEP=0 swift test > "$T/s1.out" 2>&1; echo $? > "$T/s1.code") &
sleep 0.5
echo change >> file
FAKE_SLEEP=0 swift test > "$T/s2.out" 2>&1
wait
check "newer request supersedes the queued one" 'grep -q "superseded by a newer swift test" "$T/s1.out" && [ "$(cat "$T/s1.code")" = 0 ]'
check "superseded run never runs" '[ $(( $(runs test) - before )) = 2 ]'
cd ..

# Runaways are killed at the project's ceiling.
mkdir -p hungry && echo '{"throttle": {"maxMemory": "150MB"}}' > hungry/.turnstilerc
out="$(cd hungry && FAKE_ALLOC_MB=400 swift build 2>&1)"; code=$?
check "runaway is killed with a reason" 'echo "$out" | grep -q "turnstile: killed swift build, exceeded 150 MB" && [ $code != 0 ]'

# Memory pressure pauses the newest job and resumes it afterwards.
(cd a && FAKE_SLEEP=4 swift build > "$T/p1.out" 2>&1) &
sleep 0.5
(cd b && FAKE_SLEEP=4 swift build > "$T/p2.out" 2>&1) &
sleep 1
echo 5 > "$T/level"
sleep 2.5
echo 60 > "$T/level"
wait
check "pressure pauses the newest job" 'grep -q "turnstile: paused, memory is low" "$T/p2.out" && ! grep -q paused "$T/p1.out"'
check "paused job resumes and finishes" 'grep -q "turnstile: resumed" "$T/p2.out" && grep -q "fake swift done" "$T/p2.out"'

# SIGTERM reaches the job, and the caller sees the signal.
FAKE_SLEEP=10 swift build > /dev/null 2>&1 &
job=$!
sleep 1
kill -TERM $job
wait $job; code=$?
check "SIGTERM is forwarded" '[ $code = 143 ]'

# If the supervisor is SIGKILLed, the slot is held until its job exits, then freed.
cd a
FAKE_SLEEP=3 swift test > /dev/null 2>&1 &
sup=$!
cd ..
sleep 0.7
kill -KILL $sup
sleep 0.5
out="$(cd b && FAKE_SLEEP=0 swift test 2>&1)"
check "slot survives a SIGKILLed client, then frees" 'echo "$out" | grep -q "waiting for a test slot" && echo "$out" | grep -q "fake swift done"'
wait

# In a terminal, the job owns the tty and Ctrl-C stops it like any foreground command.
cat > "$T/ctrlc.py" <<'EOF'
import os, pty, sys, time, select
pid, fd = pty.fork()
if pid == 0:
    os.environ["FAKE_SLEEP"] = "20"
    os.execvp("sh", ["sh", "-c", 'test -t 1 && echo tty-ok; swift build; echo "status=$?"'])
out = b""
deadline = time.time() + 15
sent = False
while time.time() < deadline:
    r, _, _ = select.select([fd], [], [], 0.2)
    if r:
        try:
            chunk = os.read(fd, 4096)
        except OSError:
            break
        if not chunk:
            break
        out += chunk
    if not sent and b"fake swift build" in out:
        time.sleep(0.5)
        os.write(fd, b"\x03")
        sent = True
    if b"status=" in out:
        break
sys.stdout.write(out.decode(errors="replace"))
_, status = os.waitpid(pid, 0)
print("shell=signaled" if os.WIFSIGNALED(status) and os.WTERMSIG(status) == 2 else "shell=exit%d" % os.WEXITSTATUS(status))
EOF
out="$(TURNSTILE_AGENT=0 /usr/bin/python3 "$T/ctrlc.py")"
check "Ctrl-C in a terminal stops the job" 'echo "$out" | grep -q "tty-ok" && echo "$out" | grep -q "shell=signaled" && ! pgrep -f "sleep 20" > /dev/null'

# Status is readable by people and tools.
check "status --json" 'turnstile status --json | /usr/bin/python3 -c "import json,sys; d=json.load(sys.stdin); assert d[\"memoryLevel\"] == 60 and len(d[\"recent\"]) > 0"'
check "status text" 'turnstile status | grep -q "recent:"'
check "run gates any command, leaving its arguments alone" '[ "$(turnstile run --class test -- /bin/echo --class test)" = "--class test" ]'
check "classify explains a command" '[ "$(turnstile classify npm run test:e2e)" = "browser (npm run test:e2e)" ]'

daemon_pid() { turnstile status --json | /usr/bin/python3 -c "import json,sys; print(json.load(sys.stdin).get('daemonPid', ''))"; }

# A crashed daemon doesn't let every waiting job start at once: waiters requeue with a new daemon.
(cd a && FAKE_SLEEP=3 swift test > /dev/null 2>&1) &
sleep 0.7
before=$(runs test)
(cd b && swift test > "$T/crash.out" 2>&1; echo $? > "$T/crash.code") &
sleep 0.7
old=$(daemon_pid)
kill -9 "$old"
wait
check "waiters requeue after a daemon crash" '[ "$(cat "$T/crash.code")" = 0 ] && ! grep -q ungated "$T/crash.out" && [ -n "$(daemon_pid)" ] && [ "$(daemon_pid)" != "$old" ]'

# A deliberate stop releases waiting jobs to run ungated.
(cd a && FAKE_SLEEP=3 swift test > /dev/null 2>&1) &
sleep 0.7
(cd b && swift test > "$T/release.out" 2>&1) &
sleep 0.7
turnstile stop > /dev/null
wait
check "stop releases waiting jobs" 'grep -q "daemon stopped; running ungated" "$T/release.out" && grep -q "fake swift test" "$T/release.out"'

# `turnstile disable` turns gating off everywhere until `enable`.
turnstile disable > /dev/null
(cd a && FAKE_SLEEP=2 swift test > /dev/null 2>&1) &
sleep 0.5
start=$(date +%s)
(cd b && swift test > /dev/null 2>&1)
elapsed=$(( $(date +%s) - start ))
wait
turnstile enable > /dev/null
check "disable passes everything through" '[ $elapsed -lt 2 ] && [ ! -e "$TURNSTILE_HOME/disabled" ]'

# Config mistakes are caught with a suggestion, and a clean install passes the doctor.
mkdir -p "$T/badconfig" && echo '{"concurency": {"test": 1}}' > "$T/badconfig/config.json"
out="$(TURNSTILE_CONFIG_DIR="$T/badconfig" turnstile config check)"; code=$?
check "config check catches a typo" '[ $code = 1 ] && echo "$out" | grep -q "did you mean \"concurrency\""'
check "config check passes a valid file" 'turnstile config check > /dev/null'
out="$(TURNSTILE_HOME="$T/fresh" "$BIN" init --no-rc > /dev/null && PATH="$T/fresh/shims:$PATH" TURNSTILE_HOME="$T/fresh" turnstile doctor 2>&1)"; code=$?
TURNSTILE_HOME="$T/fresh" "$BIN" stop > /dev/null
check "doctor passes a fresh install" '[ $code = 0 ] && echo "$out" | grep -q "turnstile looks healthy"' 
out="$(TURNSTILE_HOME="$T/fresh" turnstile doctor 2>&1)"
check "doctor spots missing PATH setup" 'echo "$out" | grep -q "isn.t on this shell.s PATH"'
TURNSTILE_HOME="$T/fresh" "$BIN" stop > /dev/null

# The daemon going away fails open.
turnstile stop > /dev/null
check "no daemon still runs ungated" '[ "$(TURNSTILE_HOME=/nonexistent/x swift build 2>/dev/null | head -1)" = "fake swift build" ]'

echo
if [ $failures = 0 ]; then echo "all e2e checks passed"; else echo "$failures e2e checks failed"; echo "daemon log:"; tail -20 "$TURNSTILE_HOME/daemon.log"; exit 1; fi
