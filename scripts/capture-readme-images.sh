#!/bin/bash
# Renders the README screenshots and demo GIFs into docs/images through the app's own --demo-capture mode:
# synthetic text only, no window on screen, no microphone, network or Keychain.
set -euo pipefail
cd "$(dirname "$0")/.."
SPEECH2TEXT_SIGNING_IDENTITY="${SPEECH2TEXT_SIGNING_IDENTITY:--}" bash scripts/build-app.sh >/dev/null
WORK="$(mktemp -d "${TMPDIR:-/tmp}/malgeul-capture.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
# The hardened runtime refuses the ad-hoc-signed Sparkle framework, so a scratch copy is re-signed without it.
ditto build/Speech2Text.app "$WORK/Speech2Text.app"
codesign --force --deep --sign - "$WORK/Speech2Text.app" 2>/dev/null
for lang in en ko; do
  if [[ $lang == en ]]; then terms='("Soniox", "Malgeul", "SwiftUI")'; enter="send enter"
  else terms='("말글", "Soniox", "스위프트")'; enter="엔터 보내기"; fi
  # Launch-argument defaults keep this Mac's stored settings out of the pictures; the capture writes none back.
  "$WORK/Speech2Text.app/Contents/MacOS/Speech2Text" --demo-capture "$WORK/$lang" --demo "$lang" \
    -AppleLanguages "($lang)" -inputDeviceUID demo-mic -shortcuts x -wakeListeningEnabled NO \
    -wakePhrase "Hey Computer" -wakeSensitivity standard -commandJudge jev \
    -punctuationStyle asIs -spokenEnterEnabled YES -spokenEnterPhrase "$enter" -marksUncertainWords NO \
    -silenceStopSeconds 30 -overlayAutoCloseSeconds 30 -dictionaryTerms "$terms"
  ffmpeg -y -loglevel error -framerate 12 -i "$WORK/$lang/frames-$lang/frame-%03d.png" \
    -vf "fps=12,scale=1280:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=256:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle" \
    -loop 0 "$WORK/$lang/demo-$lang.gif"
  cp "$WORK/$lang"/*.png "$WORK/$lang/demo-$lang.gif" docs/images/
done
ls -l docs/images
