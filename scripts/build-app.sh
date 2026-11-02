#!/usr/bin/env bash
# Builds Codec.app into ./build. Usage: scripts/build-app.sh [debug|release]
#
# For a release (scripts/release.sh sets these):
#   ARCHS                "arm64 x86_64" builds one universal binary; default: this Mac's architecture
#   CODEC_VERSION        the version to stamp (1.2.0); default: the latest v* tag, else Info.plist's
#   CODEC_BUILD          the build number; default: the number of commits
#   CODEC_SIGN_IDENTITY  an identity in the keychain to sign with: a Developer ID Application one
#                        signs with the hardened runtime, for notarizing; another (the self-signed
#                        one from make-signing-certificate.sh) gives every build the same identity;
#                        default: signed ad hoc
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
APP="build/Codec.app"

ARCH_FLAGS=()
for arch in ${ARCHS:-}; do ARCH_FLAGS+=(--arch "$arch"); done
# bash 3.2, which macOS has, calls an empty array unbound under `set -u`.
swift build -j "${JOBS:-2}" -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN="$(swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"

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

# The version the update check compares with the latest release.
VERSION="${CODEC_VERSION:-$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || true)}"
VERSION="${VERSION#v}"
BUILD="${CODEC_BUILD:-$(git rev-list --count HEAD 2>/dev/null || true)}"
[[ -n "$VERSION" ]] && /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
[[ -n "$BUILD" ]] && /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$APP/Contents/Info.plist"

IDENTITY="${CODEC_SIGN_IDENTITY:-}"
if [[ "$IDENTITY" == "Developer ID Application:"* ]]; then
  codesign --force --options runtime --timestamp --entitlements Resources/Codec.entitlements \
    --sign "$IDENTITY" "$APP"
  codesign --verify --strict --verbose=2 "$APP"
elif [[ -n "$IDENTITY" && "$IDENTITY" != "-" ]]; then
  # Apple's timestamps and the hardened runtime are for notarizing, which needs a Developer ID.
  codesign --force --timestamp=none --sign "$IDENTITY" "$APP"
  codesign --verify --strict "$APP"
else
  codesign --force --deep --sign - "$APP" >/dev/null
fi
echo "Built $APP $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
