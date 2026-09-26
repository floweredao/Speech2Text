#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
SIGNING_IDENTITY="${SPEECH2TEXT_SIGNING_IDENTITY:-Apple Development}"
ensure_stopped() {
  if pgrep -x Speech2Text >/dev/null; then
    printf '%s\n' 'Quit Speech2Text before replacing its signed app bundle.' >&2
    exit 1
  fi
}
ensure_stopped
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
mkdir -p build
STAGING="$(mktemp -d "$PWD/build/.app-stage.XXXXXX")"
APP="$PWD/build/Speech2Text.app"
cleanup() {
  if [[ -d "$STAGING/previous.app" && ! -e "$APP" ]]; then
    mv "$STAGING/previous.app" "$APP"
  fi
  rm -rf "$STAGING"
}
trap cleanup EXIT
mkdir -p "$STAGING/Speech2Text.app/Contents/MacOS"
cp "$BIN_DIR/Speech2Text" "$STAGING/Speech2Text.app/Contents/MacOS/"
cp Resources/Info.plist "$STAGING/Speech2Text.app/Contents/"
codesign --force --sign "$SIGNING_IDENTITY" --options runtime --entitlements Resources/Entitlements.plist "$STAGING/Speech2Text.app"
codesign --verify --deep --strict "$STAGING/Speech2Text.app"
ensure_stopped
if [[ -e "$APP" ]]; then mv "$APP" "$STAGING/previous.app"; fi
mv "$STAGING/Speech2Text.app" "$APP"
printf '%s\n' "$APP"
