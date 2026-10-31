#!/bin/bash
# Prints the codesigning identity scripts/build-app.sh signs the app with: SPEECH2TEXT_SIGNING_IDENTITY,
# else an installed Apple Development certificate, else ad hoc ("-"), which still builds and runs locally.
set -euo pipefail
if [[ -n "${SPEECH2TEXT_SIGNING_IDENTITY:-}" ]]; then
  printf '%s\n' "$SPEECH2TEXT_SIGNING_IDENTITY"
  exit 0
fi
if security find-identity -v -p codesigning 2>/dev/null | grep -q '"Apple Development'; then
  printf '%s\n' 'Apple Development'
  exit 0
fi
printf '%s\n' 'warning: no Apple Development certificate found; signing ad hoc. Set SPEECH2TEXT_SIGNING_IDENTITY to use your own certificate.' >&2
printf '%s\n' '-'
