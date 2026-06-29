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

echo "> swift build -c $CONFIG"
cd "$ROOT"
swift build -c "$CONFIG"

BIN_PATH="$ROOT/.build/$CONFIG/sonar-dictate"
if [ ! -x "$BIN_PATH" ]; then
  echo "x build did not produce $BIN_PATH" >&2
  exit 1
fi

echo "> assembling $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR"
cp "$BIN_PATH" "$MACOS_DIR/SonarDictate"
cp "$ROOT/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"

# SwiftPM resource bundle (Bundle.module) - the voiceprint model + Fbank constants.
# Bundle.module resolves a "<Package>_<Target>.bundle" next to the executable, so it
# must sit beside the binary in Contents/MacOS or the app can't load the model
# (the CLI in .build works because the bundle is already there).
RES_BUNDLE="$ROOT/.build/$CONFIG/SonarDictate_SonarDictate.bundle"
if [ -d "$RES_BUNDLE" ]; then
  cp -R "$RES_BUNDLE" "$MACOS_DIR/"
  echo "  bundled resources: $(basename "$RES_BUNDLE")"
else
  echo "! resource bundle not found ($RES_BUNDLE) - voiceprint model will be missing in the app"
fi

# Code signing - load-bearing for the dev loop.
#
# An UNSIGNED .app gets a fresh code hash on every rebuild, so macOS TCC
# invalidates its Accessibility grant each time (the "worked, then didn't"
# whiplash). Signing with a STABLE identity makes TCC key the grant on the
# (bundle-id + cert team) designated requirement, which is constant across
# rebuilds - so you grant Accessibility once and it sticks.
#
# We auto-pick the local "Apple Development" identity (no name/team-ID baked
# into this committed script). Override with SIGN_IDENTITY=... for a different
# cert (e.g. the Developer ID for notarized distribution). --identifier is
# pinned to the Info.plist CFBundleIdentifier so the requirement stays stable.
# First sign of a session prompts for Touch ID to unlock the signing key.
BUNDLE_ID="com.sonarmd.dictate"
if [ -z "${SIGN_IDENTITY:-}" ]; then
  # Match by SHA-1 hash, not name: the same cert can live in multiple
  # keychains, which makes name-based signing "ambiguous". The hash is unique.
  SIGN_IDENTITY="$(security find-identity -v -p codesigning | grep 'Apple Development' | grep -oE '[0-9A-F]{40}' | sed -n '1p')"
fi
if [ -n "$SIGN_IDENTITY" ]; then
  echo "> codesign: $SIGN_IDENTITY"
  codesign --force --sign "$SIGN_IDENTITY" --identifier "$BUNDLE_ID" "$APP_DIR"
  # Sign the standalone CLI binary too, with the SAME identifier + cert so it has
  # the SAME designated requirement as the .app. The DB key in the Keychain is
  # codesign-bound (see KeychainStore.swift); an UNSIGNED CLI binary has no stable
  # requirement, so macOS re-prompts for the password on every keychain access and
  # "Always Allow" never sticks (each rebuild changes the binary hash). Signing it
  # with the stable identifier makes one "Always Allow" hold across rebuilds.
  codesign --force --sign "$SIGN_IDENTITY" --identifier "$BUNDLE_ID" "$BIN_PATH"
  codesign --verify --verbose=1 "$APP_DIR" && echo "  [ok] signature valid"
else
  echo "! no Apple Development identity found - app left UNSIGNED."
  echo "  Accessibility grant will NOT persist across rebuilds. Set SIGN_IDENTITY to fix."
fi

echo "> done"
echo "  open $APP_DIR"
echo "  (first run will prompt for Microphone, Speech Recognition, and Accessibility permissions)"
