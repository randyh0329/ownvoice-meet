#!/bin/bash
# Fetches sherpa-onnx's prebuilt static libraries for Apple Silicon (the speaker detection runs on
# them) into mac/vendor/, once: a pinned release, checked against its SHA-256 before it is used.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=2.0.3
NAME="sherpa-onnx-v${VERSION}-osx-arm64-static-no-tts-lib"
SHA256=02d0059b66a8fcd20d711962943b37b59b499536077e6c3a42bb64c3d750455f
LIB=vendor/sherpa-onnx/lib

if [ -f "$LIB/libsherpa-onnx-c-api.a" ] && [ "$(cat vendor/sherpa-onnx/VERSION 2>/dev/null)" = "$VERSION" ]; then
  exit 0
fi
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
echo "fetching sherpa-onnx $VERSION static libraries…"
curl -fsSL -o "$tmp/lib.tar.bz2" "https://github.com/k2-fsa/sherpa-onnx/releases/download/v${VERSION}/${NAME}.tar.bz2"
got=$(shasum -a 256 "$tmp/lib.tar.bz2" | cut -d' ' -f1)
if [ "$got" != "$SHA256" ]; then
  echo "sherpa-onnx download does not match its checksum ($got)" >&2
  exit 1
fi
tar xjf "$tmp/lib.tar.bz2" -C "$tmp"
rm -rf vendor/sherpa-onnx
mkdir -p vendor/sherpa-onnx
mv "$tmp/$NAME/lib" "$LIB"
echo "$VERSION" > vendor/sherpa-onnx/VERSION
