#!/usr/bin/env bash
# Lint the Swift sources with SwiftLint.
#
# By default this is baseline-aware: only violations introduced AFTER the
# baseline was recorded cause a non-zero exit, so pre-existing legacy issues
# do not block the build. New code must be clean (warnings included, via
# --strict).
#
# Usage:
#   ./scripts/lint.sh              lint new issues only (baseline-aware), strict
#   ./scripts/lint.sh --all        lint everything, ignore the baseline
#   ./scripts/lint.sh --rebaseline regenerate the baseline from current state
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CONFIG="$ROOT/.swiftlint.yml"
BASELINE="$ROOT/.swiftlint-baseline.json"

if ! command -v swiftlint >/dev/null 2>&1; then
  echo "swiftlint not installed. Install it with: brew install swiftlint" >&2
  exit 1
fi

case "${1:-}" in
  --rebaseline)
    echo "writing baseline -> $BASELINE"
    swiftlint lint --config "$CONFIG" --write-baseline "$BASELINE"
    echo "baseline written."
    ;;
  --all)
    swiftlint lint --config "$CONFIG" --strict
    ;;
  "")
    if [ -f "$BASELINE" ]; then
      swiftlint lint --config "$CONFIG" --baseline "$BASELINE" --strict
    else
      echo "(no baseline yet - linting everything; create one with: ./scripts/lint.sh --rebaseline)" >&2
      swiftlint lint --config "$CONFIG" --strict
    fi
    ;;
  *)
    echo "usage: ./scripts/lint.sh [--all | --rebaseline]" >&2
    exit 2
    ;;
esac
