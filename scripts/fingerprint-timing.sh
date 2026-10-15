#!/bin/bash
# Times Workspace.inspect on a synthetic repo, or an existing repo without changing it.
set -euo pipefail

if [ "$#" -gt 1 ]; then
    echo "Usage: $0 [repo]" >&2
    exit 2
fi
if [ "$#" -eq 1 ]; then
    REPO="$(cd "$1" && pwd -P)"
fi
cd "$(dirname "$0")/.."
turnstile run --class compile -- swift build --build-tests -q --jobs 4

run() {
    echo "== $1"
    turnstile run --class test -- env TURNSTILE_FINGERPRINT_REPO="$2" \
        swift test --skip-build --filter timesTheFingerprintOnALargeRepo 2>&1 | rg 'fingerprint ms'
}

if [ "$#" -eq 1 ]; then
    run "$REPO" "$REPO"
    exit
fi

FILES="${FILES:-60000}"
T="$(mktemp -d /tmp/turnstile-fingerprint.XXXXXX)"
trap 'rm -rf "$T"' EXIT
R="$T/repo"
mkdir -p "$R"
git -C "$R" init -q
echo "Creating $FILES files..."
/usr/bin/python3 - "$R" "$FILES" <<'PY'
import os
import subprocess
import sys

root, count = sys.argv[1], int(sys.argv[2])
for i in range(count):
    directory = os.path.join(root, "src", str(i % 200), str(i % 7))
    os.makedirs(directory, exist_ok=True)
    with open(os.path.join(directory, f"file{i}.ts"), "w") as output:
        output.write(f"export const value{i} = {i};\n" * 20)
with open(os.path.join(root, "blob.bin"), "wb") as output:
    output.write(os.urandom(41943040))
subprocess.run(["git", "-C", root, "add", "."], check=True)
subprocess.run(["git", "-C", root, "-c", "user.name=t", "-c", "user.email=t@t",
                "commit", "-qm", "init"], check=True)
paths = [path for path in subprocess.check_output(
    ["git", "-C", root, "ls-files", "-z", "src/"]).split(b"\0") if path]
index = os.stat(os.path.join(root, ".git", "index"))
for path in paths[:2000]:
    os.utime(os.path.join(os.fsencode(root), path), ns=(index.st_atime_ns, index.st_mtime_ns))
PY

run "clean, stale index" "$R"
git -C "$R" status --porcelain > /dev/null
run "clean, refreshed index" "$R"

/usr/bin/python3 - "$R" <<'PY'
import os
import subprocess
import sys

root = sys.argv[1]
paths = [path for path in subprocess.check_output(
    ["git", "-C", root, "ls-files", "-z", "src/"]).split(b"\0") if path]
for path in paths[:2000]:
    with open(os.path.join(os.fsencode(root), path), "a") as output:
        output.write("// edit\n")
os.mkdir(os.path.join(root, "untracked"))
for i in range(3000):
    with open(os.path.join(root, "untracked", f"u{i}.ts"), "w") as output:
        output.write(f"{i}\n")
PY
run "2,000 modified + 3,000 untracked" "$R"

/usr/bin/python3 - "$R/blob.bin" <<'PY'
import os
import sys
with open(sys.argv[1], "wb") as output:
    output.write(os.urandom(41943040))
PY
run "same, plus a modified 40 MB binary" "$R"
