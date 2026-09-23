#!/bin/bash
# A live, self-contained turnstile for recording a demo: its own daemon, its own menu bar app, and four fake agents
# building and testing in fake repos. Nothing touches ~/.turnstile, and memory is faked so the queue looks the same
# on any Mac.
#
#   ./scripts/demo.sh start      # sandbox, daemon, menu bar app, agent traffic
#   ./scripts/demo.sh shell      # a shell wired to the demo, as "you"
#   ./scripts/demo.sh pressure   # free memory drops: the newest agent job is paused
#   ./scripts/demo.sh calm       # memory recovers: the paused job resumes
#   ./scripts/demo.sh stop       # tear it all down
#
# TURNSTILE_BIN and TURNSTILE_APP override the installed CLI and menu bar binary, to demo a local build.
set -eu

T=/tmp/turnstile-demo
BASE_LEVEL=45
PRESSURE_LEVEL=4

without_shims() { echo "$PATH" | tr ':' '\n' | grep -v '\.turnstile/shims' | paste -sd: -; }
BIN="${TURNSTILE_BIN:-$(PATH="$(without_shims)" command -v turnstile || true)}"
APP="${TURNSTILE_APP:-/Applications/Turnstile.app/Contents/MacOS/TurnstileBar}"

demo_env() {
  export TURNSTILE_HOME="$T/home" TURNSTILE_CONFIG_DIR="$T/config" TURNSTILE_MEMORY_LEVEL_FILE="$T/level"
  # The real Mac's swap and kernel pressure would otherwise hold the queue whatever the faked level says.
  export TURNSTILE_SWAP_USED_FILE="$T/swap" TURNSTILE_PRESSURE_LEVEL_FILE="$T/pressure"
  export PATH="$T/home/shims:$T/bin:$(without_shims)"
  unset TURNSTILE_TOKEN TURNSTILE_DISABLE
}

write_tools() {
  mkdir -p "$T/bin"
  # Prints each step spread over a random duration between $1 and $2 seconds.
  cat > "$T/bin/_work" <<'EOF'
#!/bin/bash
low=$1 high=$2; shift 2
total=$(( low + RANDOM % (high - low + 1) ))
gap=$(awk -v t="$total" -v n="$#" 'BEGIN { printf "%.2f", t / n }')
for step in "$@"; do sleep "$gap"; echo "$step"; done
EOF
  cat > "$T/bin/swift" <<'EOF'
#!/bin/bash
case "$1" in
  build) echo "Building for debugging..."
    _work 18 30 "[24/186] Compiling ApiCore Router.swift" "[71/186] Compiling ApiCore Session.swift" \
      "[128/186] Compiling ApiServer Handlers.swift" "[186/186] Linking api" "Build complete!" ;;
  test) echo "Building for debugging..."
    _work 12 22 "[186/186] Linking apiPackageTests" "Test Suite 'All tests' started" \
      "Test Suite 'RouterTests' passed" "Test Suite 'SessionTests' passed" "Executed 214 tests, with 0 failures" ;;
  *) echo "Swift version 6.2 (swift-6.2-RELEASE)" ;;
esac
EOF
  cat > "$T/bin/cargo" <<'EOF'
#!/bin/bash
case "$1" in
  build) _work 16 28 "   Compiling serde v1.0.219" "   Compiling tokio v1.47.1" "   Compiling engine-core v0.4.0" \
      "   Compiling engine v0.4.0" "    Finished \`dev\` profile [unoptimized + debuginfo] target(s)" ;;
  test) _work 12 20 "   Compiling engine v0.4.0" "     Running unittests src/lib.rs" "test result: ok. 96 passed; 0 failed" \
      "   Doc-tests engine" "test result: ok. 12 passed; 0 failed" ;;
  *) echo "cargo 1.90.0" ;;
esac
EOF
  cat > "$T/bin/npm" <<'EOF'
#!/bin/bash
[ "$1" = run ] && shift
case "$1" in
  build) printf '> web@1.0.0 build\n> next build\n'
    _work 16 26 "   Creating an optimized production build ..." " ✓ Compiled successfully" \
      " ✓ Linting and checking validity of types" " ✓ Generating static pages (48/48)" " ✓ Finalizing page optimization" ;;
  test) printf '> web@1.0.0 test\n> vitest run\n'
    _work 8 16 " ✓ src/lib/format.test.ts (22 tests)" " ✓ src/components/Cart.test.tsx (18 tests)" \
      " ✓ src/app/checkout.test.ts (31 tests)" " Test Files  24 passed (24)" "      Tests  311 passed (311)" ;;
  e2e) printf '> web@1.0.0 e2e\n> playwright test\n'
    _work 24 36 "Running 64 tests using 4 workers" "  ✓  checkout.spec.ts:12:3 › guest checkout" \
      "  ✓  auth.spec.ts:8:3 › sign in with email" "  ✓  search.spec.ts:20:3 › filters results" "  64 passed" ;;
  install|ci) echo "up to date, audited 812 packages in 1s" ;;
  *) echo "10.9.2" ;;
esac
EOF
  chmod +x "$T/bin/"*
}

write_repos() {
  local unit=$(( $(sysctl -n hw.memsize) / 16 / 1048576 ))
  mb() { awk -v u="$unit" -v x="$1" 'BEGIN { printf "\"%dMB\"", u * x }'; }
  # Memory is scaled to the machine, so a 16 GB and a 64 GB Mac show the same contention.
  cat > "$T/config/config.json" <<EOF
{"concurrency": {"compile": 3, "test": 3, "browser": 1}, "reserve": $(mb 1), "pauseBelow": 8, "resumeAbove": 30}
EOF
  mkdir -p "$T/dev/api" "$T/dev/web" "$T/dev/engine"
  cat > "$T/dev/api/.turnstilerc" <<EOF
{"commands": {"swift build": {"class": "compile", "memory": $(mb 2.5)}, "swift test": {"class": "test", "memory": $(mb 1.5)}}}
EOF
  echo 'let package = Package(name: "api")' > "$T/dev/api/Package.swift"
  cat > "$T/dev/engine/.turnstilerc" <<EOF
{"commands": {"cargo build": {"class": "compile", "memory": $(mb 2)}, "cargo test": {"class": "test", "memory": $(mb 1.5)}}}
EOF
  printf '[package]\nname = "engine"\n' > "$T/dev/engine/Cargo.toml"
  cat > "$T/dev/web/.turnstilerc" <<EOF
{"scripts": {"build": {"class": "compile", "memory": $(mb 2)}, "test": {"class": "test", "memory": $(mb 1)}, "e2e": {"class": "browser", "memory": $(mb 1.5)}}}
EOF
  echo '{"name": "web", "scripts": {"build": "next build", "test": "vitest run", "e2e": "playwright test"}}' > "$T/dev/web/package.json"
  # Git repos, so the same command on the same tree merges into the run in progress.
  for repo in api web engine; do
    git -C "$T/dev/$repo" init -q && git -C "$T/dev/$repo" add -A &&
      git -C "$T/dev/$repo" -c user.name=demo -c user.email=demo@example.com commit -qm init
  done
}

write_agents() {
  cat > "$T/agent.sh" <<'EOF'
#!/bin/bash
# agent.sh <marker> <repo> <delay> <command>... — loops its commands forever, like an agent iterating.
marker=$1 repo=$2; sleep "$3"; shift 3
export TURNSTILE_AGENT=1 "$marker=1"
cd "/tmp/turnstile-demo/dev/$repo"
while true; do
  for command in "$@"; do
    $command < /dev/null > /dev/null 2>&1
    sleep $(( 2 + RANDOM % 5 ))
  done
done
EOF
  chmod +x "$T/agent.sh"
  cat > "$T/rc" <<EOF
export BASH_SILENCE_DEPRECATION_WARNING=1 TURNSTILE_AGENT=0
export TURNSTILE_HOME="$TURNSTILE_HOME" TURNSTILE_CONFIG_DIR="$TURNSTILE_CONFIG_DIR" TURNSTILE_MEMORY_LEVEL_FILE="$TURNSTILE_MEMORY_LEVEL_FILE"
export TURNSTILE_SWAP_USED_FILE="$TURNSTILE_SWAP_USED_FILE" TURNSTILE_PRESSURE_LEVEL_FILE="$TURNSTILE_PRESSURE_LEVEL_FILE"
export PATH="$PATH"
unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT CODEX_THREAD_ID
PS1='\[\e[2m\]\W\[\e[0m\] \$ '
cd "$T/dev"
EOF
}

start() {
  [ -n "$BIN" ] || { echo "turnstile isn't installed; set TURNSTILE_BIN" >&2; exit 1; }
  [ -x "$APP" ] || { echo "menu bar app not found at $APP; set TURNSTILE_APP" >&2; exit 1; }
  [ -d "$T" ] && { echo "a demo is already set up; run $0 stop first" >&2; exit 1; }
  demo_env
  mkdir -p "$T/config"
  echo "$BASE_LEVEL" > "$T/level"
  echo 0 > "$T/swap"
  echo 1 > "$T/pressure"
  write_tools
  write_repos
  write_agents
  # Where init would install the CLI; without it the menu bar app says nothing is gated.
  mkdir -p "$T/home/bin"
  ln -s "$BIN" "$T/home/bin/turnstile"
  "$BIN" shims > /dev/null

  nohup "$BIN" daemon --idle-exit 86400 >> "$T/home/daemon.log" 2>&1 &
  echo $! > "$T/daemon.pid"
  if pgrep -xq TurnstileBar; then
    echo "Quit your own menu bar app so only the demo's icon shows (it's the same binary)."
  fi
  nohup "$APP" > /dev/null 2>&1 &
  echo $! > "$T/app.pid"

  : > "$T/agents.pid"
  agent() { nohup "$T/agent.sh" "$@" > /dev/null 2>&1 & echo $! >> "$T/agents.pid"; }
  agent CLAUDECODE api 0 "swift build" "swift test"
  agent CODEX_THREAD_ID engine 3 "cargo build" "cargo test"
  agent CLAUDECODE web 6 "npm run build" "npm test"
  agent CURSOR_AGENT web 9 "npm run e2e" "npm test"
  echo "Demo running. In another terminal: $0 shell"
}

stop() {
  [ -d "$T" ] || { echo "no demo running"; return; }
  demo_env
  for file in agents app daemon; do
    [ -f "$T/$file.pid" ] && xargs kill 2> /dev/null < "$T/$file.pid" || true
  done
  "$BIN" stop > /dev/null 2>&1 || true
  pkill -f "$T/bin/" 2> /dev/null || true
  rm -rf "$T"
  echo "Demo stopped. Reopen your own menu bar app if you quit it."
}

case "${1:-}" in
  start) start ;;
  stop) stop ;;
  shell) [ -f "$T/rc" ] || { echo "run $0 start first" >&2; exit 1; }
    exec /bin/bash --rcfile "$T/rc" -i ;;
  pressure) echo "$PRESSURE_LEVEL" > "$T/level"; demo_env
    # A pause needs two agent jobs running, and never takes the oldest.
    for _ in $(seq 20); do
      paused="$("$BIN" status | grep 'paused]' || true)"
      [ -n "$paused" ] && { echo "$paused"; exit 0; }
      sleep 1
    done
    echo "nothing paused yet; it will once two agent jobs are running" ;;
  calm) echo "$BASE_LEVEL" > "$T/level"; echo "memory back to $BASE_LEVEL% free; paused jobs resume shortly" ;;
  *) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
