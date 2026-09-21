#!/bin/bash
# Records website/static/img/demo.svg: two agents start builds, the second waits for memory, both finish.
# The turnstile lines are real output from a throwaway turnstile home; the tools are fakes, and memory is faked.
set -eu

cd "$(dirname "$0")/.."
ROOT="$PWD"
OUT="${1:-$ROOT/website/static/img/demo.svg}"
CALLER_PATH="$PATH"
if [ -z "${TURNSTILE_BIN:-}" ]; then
  swift build -q
  TURNSTILE_BIN="$(swift build --show-bin-path)/turnstile"
fi

T="$(mktemp -d /tmp/turnstile-demo.XXXXXX)"
export TURNSTILE_HOME="$T/home"
export TURNSTILE_CONFIG_DIR="$T/config"
export TURNSTILE_MEMORY_LEVEL_FILE="$T/level"
export TURNSTILE_AGENT=1
unset TURNSTILE_TOKEN TURNSTILE_DISABLE
cleanup() { PATH="$TURNSTILE_HOME/shims:$PATH" turnstile stop > /dev/null 2>&1; rm -rf "$T"; }
trap cleanup EXIT

mkdir -p "$T/bin" "$T/config" "$T/dev/api" "$T/dev/web"
echo '{"reserve": "2GB"}' > "$T/config/config.json"
# About 10 GB free, so a 6 GB build leaves too little for a 5 GB one.
echo $(( 10 * 1024 * 1024 * 1024 * 100 / $(sysctl -n hw.memsize) )) > "$T/level"
echo '{"commands": {"swift build": {"class": "compile", "memory": "6GB"}}}' > "$T/dev/api/.turnstilerc"
echo '{"scripts": {"build": {"class": "compile", "memory": "5GB"}}}' > "$T/dev/web/.turnstilerc"
echo '{"name": "web", "scripts": {"build": "next build"}}' > "$T/dev/web/package.json"

cat > "$T/bin/swift" <<'EOF'
#!/bin/bash
echo "Building for debugging..."
for step in "[18/112] Compiling ApiCore Router.swift" "[64/112] Compiling ApiServer Handlers.swift" "[112/112] Linking api"; do
  sleep 1.4; echo "$step"
done
echo "Build complete! (4.5s)"
EOF
cat > "$T/bin/npm" <<'EOF'
#!/bin/bash
printf '> web@1.0.0 build\n> next build\n'
sleep 1; echo "   Creating an optimized production build ..."
sleep 1.5; echo " ✓ Compiled successfully"
sleep 1; echo " ✓ Generating static pages (24/24)"
EOF
chmod +x "$T/bin/swift" "$T/bin/npm"

export PATH="$TURNSTILE_HOME/shims:$T/bin:/usr/bin:/bin"
"$TURNSTILE_BIN" shims > /dev/null

/usr/bin/python3 - "$T/demo.cast" "$T/dev" <<'EOF'
import json, subprocess, sys, threading, time

cast, dev = sys.argv[1:]
events, lock, start = [], threading.RLock(), time.monotonic()
DIM, BOLD, YELLOW, RESET = "\x1b[2m", "\x1b[1m", "\x1b[33m", "\x1b[0m"
LABELS = {"agent 1": "\x1b[36m", "agent 2": "\x1b[35m", "you": "\x1b[32m"}

def emit(text):
    with lock:
        events.append([round(time.monotonic() - start, 3), "o", text])

def label(who):
    return f"{LABELS[who]}{who:>7}{RESET} {DIM}│{RESET} "

def line(who, text):
    if text.startswith("turnstile:"):
        text = f"{YELLOW}{text}{RESET}"
    emit(label(who) + text + "\r\n")

def typed(who, cwd, command):
    with lock:  # hold the agents' output until the command is typed
        emit(f"{label(who)}{DIM}{cwd} ${RESET} ")
        for char in command:
            time.sleep(0.045)
            emit(BOLD + char + RESET)
        time.sleep(0.3)
        emit("\r\n")

def run(who, project, command):
    process = subprocess.Popen(command, cwd=f"{dev}/{project}", stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    def pump():
        for text in process.stdout:
            line(who, text.rstrip("\n"))
    thread = threading.Thread(target=pump)
    thread.start()
    return process, thread

emit(f"{DIM}# Two coding agents start builds in different repos at once.{RESET}\r\n\r\n")
time.sleep(0.8)
typed("agent 1", "~/dev/api", "swift build")
first = run("agent 1", "api", ["swift", "build"])
time.sleep(1.0)
typed("agent 2", "~/dev/web", "npm run build")
second = run("agent 2", "web", ["npm", "run", "build"])
time.sleep(1.2)
with lock:  # keep the status block together
    typed("you", "~", "turnstile status")
    status = subprocess.run(["turnstile", "status"], capture_output=True, text=True).stdout
    for text in status.splitlines():
        if text.strip():
            line("you", text)
for process, thread in (first, second):
    process.wait()
    thread.join()
time.sleep(0.4)
emit(f"\r\n{DIM}# The second build waited for memory instead of starting alongside the first.{RESET}\r\n")
time.sleep(2.5)
emit("")

with open(cast, "w") as file:
    file.write(json.dumps({"version": 2, "width": 110, "height": 26}) + "\n")
    for event in events:
        file.write(json.dumps(event) + "\n")
EOF

[ -n "${CAST_OUT:-}" ] && cp "$T/demo.cast" "$CAST_OUT"
# Rendered outside the throwaway home, so it's gated like any other command.
env -u TURNSTILE_HOME -u TURNSTILE_CONFIG_DIR -u TURNSTILE_MEMORY_LEVEL_FILE -u TURNSTILE_AGENT PATH="$CALLER_PATH" \
  npx -y svg-term-cli@2.1.1 --in "$T/demo.cast" --out "$OUT" --window --width 110 --height 26 --padding 12
echo "wrote $OUT"
