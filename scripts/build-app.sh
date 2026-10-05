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
# SwiftPM records the deployment target as the linked SDK version. Record 26.0
# so macOS 26 and later keep the same runtime behavior as the 26-only releases.
swift build -c release -Xlinker -platform_version -Xlinker macos -Xlinker 15.0 -Xlinker 26.0
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
ICONSET="$STAGING/AppIcon.iconset"
mkdir -p "$ICONSET" "$STAGING/Speech2Text.app/Contents/Resources"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  sips -z "$((size * 2))" "$((size * 2))" Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$STAGING/Speech2Text.app/Contents/Resources/AppIcon.icns"
cp -R Resources/en.lproj Resources/ko.lproj "$STAGING/Speech2Text.app/Contents/Resources/"
codesign --force --sign "$SIGNING_IDENTITY" --options runtime --entitlements Resources/Entitlements.plist "$STAGING/Speech2Text.app"
codesign --verify --deep --strict "$STAGING/Speech2Text.app"
ensure_stopped
if [[ -e "$APP" ]]; then mv "$APP" "$STAGING/previous.app"; fi
mv "$STAGING/Speech2Text.app" "$APP"
printf '%s\n' "$APP"
