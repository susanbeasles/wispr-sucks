#!/usr/bin/env bash
# Build SonarDictate.app from the swift package.
#
# macOS terminates Speech / AVAudioEngine binaries that lack an Info.plist with
# NSMicrophoneUsageDescription + NSSpeechRecognitionUsageDescription. Swift
# Package Manager produces a CLI binary without an Info.plist, so we wrap it
# in a minimal .app bundle.
#
# Usage:
#   ./scripts/build-app.sh [debug|release]
#
# Output:
#   dist/SonarDictate.app

set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT/dist/SonarDictate.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"

echo "▶ swift build -c $CONFIG"
cd "$ROOT"
swift build -c "$CONFIG"

BIN_PATH="$ROOT/.build/$CONFIG/sonar-dictate"
if [ ! -x "$BIN_PATH" ]; then
  echo "✗ build did not produce $BIN_PATH" >&2
  exit 1
fi

echo "▶ assembling $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR"
cp "$BIN_PATH" "$MACOS_DIR/SonarDictate"
cp "$ROOT/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"

echo "▶ done"
echo "  open $APP_DIR"
echo "  (first run will prompt for Microphone, Speech Recognition, and Accessibility permissions)"
