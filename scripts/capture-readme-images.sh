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
  # H.264 in yuv420p with the index up front plays inline on GitHub, in Safari and in QuickTime. The README links
  # the uploaded copy (github.com/user-attachments), because GitHub strips <video> tags pointing into the repository.
  ffmpeg -y -loglevel error -framerate 9 -i "$WORK/$lang/frames-$lang/frame-%03d.png" \
    -vf "scale=1280:-2:flags=lanczos,tpad=stop_mode=clone:stop_duration=1.5,fps=30,crop=1280:320:0:16,format=yuv420p" -c:v libx264 -preset slow -crf 18 \
    -movflags +faststart -an "$WORK/$lang/demo-$lang.mp4"
  # The last frame is the README poster: an image renders everywhere, including the GitHub app and logged-out views.
  ffmpeg -y -loglevel error -sseof -0.3 -i "$WORK/$lang/demo-$lang.mp4" -frames:v 1 "$WORK/$lang/demo-poster-$lang.png"
  cp "$WORK/$lang"/*.png docs/images/
  mkdir -p docs/videos
  cp "$WORK/$lang/demo-$lang.mp4" docs/videos/
done
ls -l docs/images docs/videos
