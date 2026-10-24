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
bash scripts/fetch-wake-model.sh
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
cp LICENSE THIRD_PARTY_NOTICES.md "$STAGING/Speech2Text.app/Contents/Resources/"
# The on-device wake-phrase model (Apache-2.0); its sample recordings stay out of the app.
mkdir -p "$STAGING/Speech2Text.app/Contents/Resources/WakeWord"
cp Vendor/wake-model/encoder.onnx Vendor/wake-model/decoder.onnx Vendor/wake-model/joiner.onnx \
  Vendor/wake-model/tokens.txt Vendor/wake-model/bpe.model "$STAGING/Speech2Text.app/Contents/Resources/WakeWord/"
# Shortcuts and Voice Control find the App Intents through Metadata.appintents. Xcode normally writes it;
# the Command Line Tools lack the processor, so take it from Xcode and feed it the compiler's constant values.
XCODE_TOOLCHAIN="${SPEECH2TEXT_XCODE_TOOLCHAIN:-/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain}"
INTENTS_PROCESSOR="$XCODE_TOOLCHAIN/usr/bin/appintentsmetadataprocessor"
[[ -x "$INTENTS_PROCESSOR" ]] || { printf '%s\n' "App Intents metadata processor not found at $INTENTS_PROCESSOR." >&2; exit 1; }
INTENTS="$STAGING/intents"
mkdir -p "$INTENTS"
find "$PWD/Sources/Speech2Text" -name '*.swift' | sort > "$INTENTS/sources.txt"
printf '%s' '["AppIntent","EntityQuery","AppEntity","TransientEntity","AppEnum","AppShortcutProviding","AppShortcutsProvider","AnyResolverProviding","AppIntentsPackage","DynamicOptionsProvider"]' > "$INTENTS/protocols.json"
SDK_ROOT="$(xcrun --sdk macosx --show-sdk-path)"
swiftc -wmo -parse-as-library -swift-version 6 -module-name Speech2Text -sdk "$SDK_ROOT" -target arm64-apple-macos15.0 \
  -I "$BIN_DIR" -I "$PWD/Sources/CSherpaOnnx/include" -F "$BIN_DIR" -emit-module -emit-module-path "$INTENTS/Speech2Text.swiftmodule" \
  -emit-const-values-path "$INTENTS/Speech2Text.swiftconstvalues" \
  -Xfrontend -const-gather-protocols-file -Xfrontend "$INTENTS/protocols.json" $(cat "$INTENTS/sources.txt")
printf '%s\n' "$INTENTS/Speech2Text.swiftconstvalues" > "$INTENTS/constvalues.txt"
"$INTENTS_PROCESSOR" --toolchain-dir "$XCODE_TOOLCHAIN" --module-name Speech2Text --sdk-root "$SDK_ROOT" \
  --xcode-version "$(/usr/libexec/PlistBuddy -c 'Print :ProductBuildVersion' "$XCODE_TOOLCHAIN/../../../version.plist")" \
  --platform-family macOS --deployment-target 15.0 --target-triple arm64-apple-macos15.0 \
  --source-file-list "$INTENTS/sources.txt" --swift-const-vals-list "$INTENTS/constvalues.txt" \
  --output "$STAGING/Speech2Text.app/Contents/Resources" --force
[[ -f "$STAGING/Speech2Text.app/Contents/Resources/Metadata.appintents/extract.actionsdata" ]] \
  || { printf '%s\n' 'App Intents metadata was not produced.' >&2; exit 1; }
# Embed the SwiftPM-resolved Sparkle (pinned in Package.swift); ditto keeps its symlinks and helpers.
SPARKLE="$(find .build/artifacts -maxdepth 6 -path '*macos-arm64_x86_64/Sparkle.framework' | head -1)"
[[ -n "$SPARKLE" ]] || { printf '%s\n' 'Sparkle.framework not found under .build/artifacts.' >&2; exit 1; }
FRAMEWORK="$STAGING/Speech2Text.app/Contents/Frameworks/Sparkle.framework"
mkdir -p "$(dirname "$FRAMEWORK")"
ditto "$SPARKLE" "$FRAMEWORK"
# Sign nested Sparkle code inside-out with the same certificate, keeping each helper's entitlements.
for component in Versions/B/XPCServices/Installer.xpc Versions/B/XPCServices/Downloader.xpc \
  Versions/B/Autoupdate Versions/B/Updater.app; do
  codesign --force --sign "$SIGNING_IDENTITY" --options runtime --preserve-metadata=entitlements "$FRAMEWORK/$component"
done
codesign --force --sign "$SIGNING_IDENTITY" --options runtime --preserve-metadata=entitlements "$FRAMEWORK"
codesign --force --sign "$SIGNING_IDENTITY" --options runtime --entitlements Resources/Entitlements.plist "$STAGING/Speech2Text.app"
codesign --verify --deep --strict "$STAGING/Speech2Text.app"
ensure_stopped
if [[ -e "$APP" ]]; then mv "$APP" "$STAGING/previous.app"; fi
mv "$STAGING/Speech2Text.app" "$APP"
printf '%s\n' "$APP"
