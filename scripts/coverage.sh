#!/bin/bash
# Runs the unit tests with coverage, prints a per-file report of Sources/, and writes .build/coverage.lcov.
set -euo pipefail

cd "$(dirname "$0")/.."
swift test --enable-code-coverage "$@"

BIN_PATH="$(swift build --show-bin-path)"
PROFDATA="$BIN_PATH/codecov/default.profdata"
IGNORE='(Tests|\.build)/'

# The native build system makes one turnstilePackageTests bundle, swiftbuild one bundle per test target.
OBJECTS=()
for bundle in "$BIN_PATH"/*.xctest; do
    OBJECTS+=(-object "$bundle/Contents/MacOS/$(basename "$bundle" .xctest)")
done
[ ${#OBJECTS[@]} -gt 0 ] || { echo "no test bundles in $BIN_PATH" >&2; exit 1; }

xcrun llvm-cov report "${OBJECTS[@]}" -instr-profile "$PROFDATA" -ignore-filename-regex "$IGNORE"
xcrun llvm-cov export "${OBJECTS[@]}" -instr-profile "$PROFDATA" -ignore-filename-regex "$IGNORE" -format lcov \
    > .build/coverage.lcov
