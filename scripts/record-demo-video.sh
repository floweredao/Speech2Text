#!/bin/bash
# Films the README demo of the real app at 60 fps: scripts/record-demo creates a virtual display, runs the app's
# scripted demo on it (--demo-screen) and records that display, so nothing appears on the screens anyone is working
# on and no microphone, network or other app is involved. Needs Screen Recording permission for the parent terminal.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
WORK="$(mktemp -d "$PWD/.work/demo-video.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

SPEECH2TEXT_SIGNING_IDENTITY="${SPEECH2TEXT_SIGNING_IDENTITY:--}" bash scripts/build-app.sh >/dev/null
cp -R build/Speech2Text.app "$WORK/demo.app"
# The scratch copy is re-signed ad hoc as a whole, so an ad-hoc build can still load its own Sparkle framework.
codesign --force --deep -s - "$WORK/demo.app" 2>/dev/null
swiftc -O -import-objc-header scripts/record-demo/VirtualDisplay.h scripts/record-demo/main.swift -o "$WORK/record-demo"

# The app's windows sit in the middle of the 1280x800 pt display; the crop keeps them and drops the menu bar, which
# belongs to whichever app is frontmost on this Mac.
CROP="crop=1600:1020:480:68"
mkdir -p docs/videos
for lang in en ko; do
  "$WORK/record-demo" "$WORK/demo.app/Contents/MacOS/Speech2Text" "$lang" "$WORK/raw-$lang.mov"
  # Recording starts before the app's windows exist and stops after they are gone. Both ends are cut on the frames
  # where the whole screen changes, so the video opens on the app and never shows an empty desktop.
  CHANGES="$(ffmpeg -hide_banner -loglevel info -i "$WORK/raw-$lang.mov" \
    -vf "select='gt(scene,0.08)',showinfo" -an -f null - 2>&1 |
    awk -F'pts_time:' '/pts_time/ { split($2, a, " "); print a[1] }')"
  START="$(printf '%s\n' "$CHANGES" | head -1)"
  END="$(printf '%s\n' "$CHANGES" | tail -1)"
  [[ -n "$START" && -n "$END" && "$START" != "$END" ]] || { printf '%s\n' "no window change found in $lang recording" >&2; exit 70; }
  DURATION="$(awk -v a="$START" -v b="$END" 'BEGIN { printf "%.3f", b - a - 0.05 }')"
  ffmpeg -y -loglevel error -ss "$START" -i "$WORK/raw-$lang.mov" -t "$DURATION" \
    -vf "$CROP,fps=60,scale=1280:-2,format=yuv420p" -c:v libx264 -preset slow -crf 18 \
    -profile:v high -movflags +faststart -an "docs/videos/demo-$lang.mp4"
  ffprobe -v error -show_entries stream=width,height,avg_frame_rate,nb_frames \
    -show_entries format=duration,size -of compact "docs/videos/demo-$lang.mp4"
done
