#!/usr/bin/env bash
# Builds Codec.app into ./build. Usage: scripts/build-app.sh [debug|release]
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
APP="build/Codec.app"

swift build -j "${JOBS:-2}" -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)"

if [[ ! -f build/AppIcon.icns || scripts/make-icon.swift -nt build/AppIcon.icns ]]; then
  ICONSET="build/AppIcon.iconset"
  rm -rf "$ICONSET" && mkdir -p "$ICONSET"
  swift scripts/make-icon.swift build/AppIcon-1024.png
  for s in 16 32 128 256 512; do
    sips -z $s $s build/AppIcon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) build/AppIcon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o build/AppIcon.icns
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Codec" "$APP/Contents/MacOS/Codec"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Codec sound files are optional and not in the repository; without them the app synthesizes its cues.
if compgen -G "Resources/Sounds/*.mp3" >/dev/null; then
  mkdir -p "$APP/Contents/Resources/Sounds"
  cp Resources/Sounds/*.mp3 "$APP/Contents/Resources/Sounds/"
fi
# SwiftPM resource bundles, if any dependency ships them.
find "$BIN" -maxdepth 1 -name "*.bundle" -exec cp -R {} "$APP/Contents/Resources/" \;

codesign --force --deep --sign - "$APP" >/dev/null
echo "Built $APP"
