#!/bin/bash
# Writes the Homebrew formula for a release tarball: scripts/formula.sh <version> <tarball> > turnstile.rb
set -euo pipefail
version="$1"
sha="$(shasum -a 256 "$2" | cut -d' ' -f1)"
sed -e "s/@VERSION@/$version/g" -e "s/@SHA256@/$sha/g" "$(dirname "$0")/../packaging/turnstile.rb.template"
