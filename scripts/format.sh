#!/usr/bin/env bash
# Format (or check) the Swift sources with swift-format - Apple's formatter,
# shipped inside the Swift 6 toolchain, so there is nothing to install. This is
# the "Prettier for Swift". Style is driven by ../.swift-format.
#
# Usage:
#   ./scripts/format.sh            check formatting; non-zero exit if unformatted
#   ./scripts/format.sh apply      reformat Sources/ in place
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CONFIG="$ROOT/.swift-format"
SRC="$ROOT/Sources"

if ! swift format --version >/dev/null 2>&1; then
  echo "swift-format unavailable. It ships with the Swift 6 toolchain (Xcode 16+)." >&2
  exit 1
fi

case "${1:-check}" in
  apply|fix|format)
    echo "formatting $SRC in place..."
    swift format --configuration "$CONFIG" --in-place --recursive "$SRC"
    echo "done. review with: git diff"
    ;;
  check|lint)
    # Accurate check: a file is "formatted" only if running the formatter over
    # it is a no-op. (swift-format's `lint` mode under-reports whitespace-only
    # changes, so diff against the formatter's own output instead.)
    fail=0
    while IFS= read -r f; do
      if ! swift format --configuration "$CONFIG" "$f" 2>/dev/null | diff -q "$f" - >/dev/null 2>&1; then
        echo "needs formatting: $f"
        fail=1
      fi
    done < <(find "$SRC" -name '*.swift')
    if [ "$fail" -eq 0 ]; then
      echo "all files formatted."
    else
      echo "run: ./scripts/format.sh apply" >&2
      exit 1
    fi
    ;;
  *)
    echo "usage: ./scripts/format.sh [check | apply]" >&2
    exit 2
    ;;
esac
