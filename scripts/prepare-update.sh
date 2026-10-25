#!/bin/bash
# Builds the signed update assets for one GitHub release: the app ZIP, appcast.xml, and SHA256SUMS.
# usage: scripts/prepare-update.sh Sparkle-2.9.6.tar.xz output-dir
# The EdDSA private key stays in the login keychain (account local.speech2text.sparkle).
set -euo pipefail
cd "$(dirname "$0")/.."
# Official Sparkle 2.9.6 tools archive, matching the framework pinned in Package.swift.
SPARKLE_SHA256=52bf9e88cdd972fc0c81501377a880e90d47031bd8ca5462488f843e2609e192
KEY_ACCOUNT=local.speech2text.sparkle
APP=build/Speech2Text.app
[[ $# -eq 2 ]] || { printf '%s\n' "usage: $0 Sparkle-2.9.6.tar.xz output-dir" >&2; exit 64; }
ARCHIVE_TOOLS="$1"
OUTPUT="$2"
[[ ! -e "$OUTPUT" ]] || { printf '%s\n' 'Output directory must not exist yet.' >&2; exit 64; }
[[ "$(shasum -a 256 "$ARCHIVE_TOOLS" | awk '{print $1}')" == "$SPARKLE_SHA256" ]] \
  || { printf '%s\n' 'Tools archive is not the official Sparkle 2.9.6.' >&2; exit 65; }
codesign --verify --deep --strict "$APP"
INFO="$APP/Contents/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO")"
PUBLIC_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$INFO")"
STAGING="$(mktemp -d "$PWD/build/.update.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
mkdir "$STAGING/tools" "$STAGING/release"
tar -xf "$ARCHIVE_TOOLS" -C "$STAGING/tools"
TOOLS="$STAGING/tools/bin"
# -p only reads the existing key; a mismatch stops before any asset is written.
[[ "$("$TOOLS/generate_keys" --account "$KEY_ACCOUNT" -p)" == "$PUBLIC_KEY" ]] \
  || { printf '%s\n' 'Keychain Sparkle key does not match SUPublicEDKey.' >&2; exit 65; }
ZIP_NAME="Speech2Text-$VERSION-macOS.zip"
ditto -c -k --keepParent "$APP" "$STAGING/release/$ZIP_NAME"
"$TOOLS/generate_appcast" --account "$KEY_ACCOUNT" --maximum-deltas 0 \
  --download-url-prefix "https://github.com/floweredao/Speech2Text/releases/download/v$VERSION/" \
  -o "$STAGING/release/appcast.xml" "$STAGING/release"
SIGNATURE="$(xmllint --xpath 'string(/rss/channel/item/enclosure/@*[local-name()="edSignature"])' "$STAGING/release/appcast.xml")"
[[ -n "$SIGNATURE" ]] || { printf '%s\n' 'Appcast has no EdDSA signature.' >&2; exit 65; }
"$TOOLS/sign_update" --account "$KEY_ACCOUNT" --verify "$STAGING/release/$ZIP_NAME" "$SIGNATURE"
(cd "$STAGING/release" && shasum -a 256 "$ZIP_NAME" appcast.xml > SHA256SUMS)
mv "$STAGING/release" "$OUTPUT"
ls "$OUTPUT"
