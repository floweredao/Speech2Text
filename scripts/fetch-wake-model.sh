#!/bin/bash
# Downloads the pinned sherpa-onnx static libraries and wake-word model into Vendor/ (not committed).
# Both are Apache-2.0. Re-running is cheap: a matching stamp skips the download.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=2.0.0
LIB_ARCHIVE="sherpa-onnx-v$VERSION-osx-arm64-static-no-tts-lib.tar.bz2"
LIB_SHA256=4ebcb7cbb1ade49b0ce17866f71b89512312c29d677f1cebaf1f08e8df8427c5
MODEL=sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01
MODEL_SHA256=f170013b4716e41b62b9bfd809687c207cef798ef9bc6534d524e17af9b6561a
STAMP="$LIB_SHA256 $MODEL_SHA256"
VENDOR="$PWD/Vendor"
if [[ "$(cat "$VENDOR/.stamp" 2>/dev/null)" == "$STAMP" ]]; then exit 0; fi
DOWNLOAD="$(mktemp -d "${TMPDIR:-/tmp}/s2t-wake.XXXXXX")"
trap 'rm -rf "$DOWNLOAD"' EXIT
fetch() {
  curl -fsSL --retry 3 -o "$DOWNLOAD/$2" "$1"
  [[ "$(shasum -a 256 "$DOWNLOAD/$2" | cut -d' ' -f1)" == "$3" ]] \
    || { printf '%s\n' "Checksum mismatch for $2." >&2; exit 1; }
  tar -xjf "$DOWNLOAD/$2" -C "$DOWNLOAD"
}
fetch "https://github.com/k2-fsa/sherpa-onnx/releases/download/v$VERSION/$LIB_ARCHIVE" lib.tar.bz2 "$LIB_SHA256"
fetch "https://github.com/k2-fsa/sherpa-onnx/releases/download/kws-models/$MODEL.tar.bz2" model.tar.bz2 "$MODEL_SHA256"
rm -rf "$VENDOR"
mkdir -p "$VENDOR/sherpa-onnx" "$VENDOR/wake-model/test_wavs"
cp -R "$DOWNLOAD/${LIB_ARCHIVE%.tar.bz2}/lib" "$VENDOR/sherpa-onnx/"
SOURCE="$DOWNLOAD/$MODEL"
cp "$SOURCE/encoder-epoch-12-avg-2-chunk-16-left-64.int8.onnx" "$VENDOR/wake-model/encoder.onnx"
cp "$SOURCE/decoder-epoch-12-avg-2-chunk-16-left-64.onnx" "$VENDOR/wake-model/decoder.onnx"
cp "$SOURCE/joiner-epoch-12-avg-2-chunk-16-left-64.int8.onnx" "$VENDOR/wake-model/joiner.onnx"
cp "$SOURCE/tokens.txt" "$SOURCE/bpe.model" "$VENDOR/wake-model/"
# The tests use the model's own sample recordings; the app bundle leaves them out.
cp "$SOURCE/test_wavs/0.wav" "$SOURCE/test_wavs/1.wav" "$VENDOR/wake-model/test_wavs/"
printf '%s' "$STAMP" > "$VENDOR/.stamp"
