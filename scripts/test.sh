#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
# Swift 6.4 CLT installs Testing outside SwiftPM's default framework search path.
# Keep real macro expansion and runtime linking enabled; no tests are excluded.
FRAMEWORKS="$DEVELOPER_DIR/Library/Developer/Frameworks"
PLUGINS="$DEVELOPER_DIR/usr/lib/swift/host/plugins/testing"
swift test --build-system native \
  -Xswiftc -F -Xswiftc "$FRAMEWORKS" \
  -Xswiftc -plugin-path -Xswiftc "$PLUGINS" \
  -Xlinker -F -Xlinker "$FRAMEWORKS" \
  -Xlinker -rpath -Xlinker "$FRAMEWORKS" "$@"
