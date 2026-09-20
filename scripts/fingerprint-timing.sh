#!/bin/bash
# Times Workspace.inspect on a large synthetic repo in each state that has been slow before.
# Run it before changing fingerprint code. Not a benchmark; the aim is p95 under 300 ms in every state.
#
#   ./scripts/fingerprint-timing.sh          # 60k tracked files
#   FILES=20000 ./scripts/fingerprint-timing.sh
#   ./scripts/fingerprint-timing.sh ~/src/big-repo   # time an existing repo as it is
set -eu

cd "$(dirname "$0")/.."
swift build --build-tests -q

run() {
    echo "== $1"
    TURNSTILE_FINGERPRINT_REPO="$2" swift test --skip-build --filter timesTheFingerprintOnALargeRepo 2>&1 | grep "fingerprint ms"
}

if [ $# -gt 0 ]; then
    run "$1" "$1"
    exit
fi

FILES="${FILES:-60000}"
T="$(mktemp -d /tmp/turnstile-fingerprint.XXXXXX)"
trap 'rm -rf "$T"' EXIT
R="$T/repo"
mkdir -p "$R"
cd "$R"
git init -q
echo "Creating $FILES files..."
/usr/bin/python3 - "$FILES" <<'EOF'
import os, sys
for i in range(int(sys.argv[1])):
    d = f"src/{i % 200}/{i % 7}"
    os.makedirs(d, exist_ok=True)
    with open(f"{d}/file{i}.ts", "w") as f:
        f.write(f"export const value{i} = {i};\n" * 20)
EOF
head -c 41943040 /dev/urandom > blob.bin
git add -A
git -c user.name=t -c user.email=t@t commit -qm init
cd - > /dev/null

# Racily clean entries: every file's mtime is the index's, so git has to re-read them.
touch -r "$R/.git/index" $(cd "$R" && git ls-files | head -2000 | sed "s|^|$R/|")
run "clean, stale index" "$R"
git -C "$R" status > /dev/null
run "clean, refreshed index" "$R"

(cd "$R" && git ls-files 'src/*' | head -2000 | while read -r f; do echo "// edit" >> "$f"; done)
mkdir -p "$R/untracked"
for i in $(seq 1 3000); do echo "$i" > "$R/untracked/u$i.ts"; done
run "2,000 modified + 3,000 untracked" "$R"

head -c 41943040 /dev/urandom > "$R/blob.bin"
run "same, plus a modified 40 MB binary" "$R"
