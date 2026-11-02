#!/usr/bin/env bash
# Builds a release: a universal Codec.app in a disk image. Usage: scripts/release.sh <version>, e.g.
# scripts/release.sh 1.2.0
#
# Without an Apple Developer Program membership, the app isn't notarized: macOS asks people to allow
# it the first time they open each version. It's signed ad hoc, or with
#   CODEC_SIGN_IDENTITY   the name of an identity in the keychain: the self-signed one from
#                         scripts/make-signing-certificate.sh keeps permissions across updates
# With a membership, CODEC_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" signs the app
# for notarizing, and it's notarized, and so is the disk image, with either
#   CODEC_NOTARY_PROFILE  a profile saved with `xcrun notarytool store-credentials`
# or an App Store Connect API key:
#   CODEC_NOTARY_KEY      the .p8 file's path
#   CODEC_NOTARY_KEY_ID   its key ID
#   CODEC_NOTARY_ISSUER   its issuer ID
# See docs/releasing.md.
#
# Writes build/Codec-<version>.dmg and prints its SHA-256.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?Usage: scripts/release.sh <version>}"
VERSION="${VERSION#v}"
IDENTITY="${CODEC_SIGN_IDENTITY:--}"
APP="build/Codec.app"
DMG="build/Codec-$VERSION.dmg"

notary=()
if [[ "$IDENTITY" != "Developer ID Application:"* ]]; then
  echo "Signing $([[ "$IDENTITY" == "-" ]] && echo "ad hoc" || echo "as $IDENTITY"), without notarizing: macOS will ask people to allow Codec the first time they open it"
elif [[ -n "${CODEC_NOTARY_PROFILE:-}" ]]; then
  notary=(--keychain-profile "$CODEC_NOTARY_PROFILE")
elif [[ -n "${CODEC_NOTARY_KEY:-}" ]]; then
  notary=(--key "$CODEC_NOTARY_KEY" --key-id "${CODEC_NOTARY_KEY_ID:?Set CODEC_NOTARY_KEY_ID}"
          --issuer "${CODEC_NOTARY_ISSUER:?Set CODEC_NOTARY_ISSUER}")
else
  echo "error: set CODEC_NOTARY_PROFILE, or CODEC_NOTARY_KEY, CODEC_NOTARY_KEY_ID and CODEC_NOTARY_ISSUER" >&2
  exit 1
fi

# Sends a file to Apple's notary service, waits for the verdict and staples the ticket to `staple`.
notarize() {
  local file="$1" staple="$2" result status id
  echo "Notarizing $(basename "$file")…"
  result="$(xcrun notarytool submit "$file" "${notary[@]}" --wait --timeout 30m --output-format json)"
  status="$(plutil -extract status raw -o - - <<<"$result")"
  if [[ "$status" != "Accepted" ]]; then
    id="$(plutil -extract id raw -o - - <<<"$result" || true)"
    echo "error: notarization of $(basename "$file") ended $status" >&2
    [[ -n "$id" ]] && xcrun notarytool log "$id" "${notary[@]}" >&2
    exit 1
  fi
  xcrun stapler staple "$staple"
}

ARCHS="arm64 x86_64" CODEC_VERSION="$VERSION" CODEC_SIGN_IDENTITY="$IDENTITY" scripts/build-app.sh release

# The app is notarized on its own first, so it carries its ticket once it's copied out of the image.
if (( ${#notary[@]} )); then
  ditto -c -k --keepParent "$APP" build/Codec-notarize.zip
  notarize build/Codec-notarize.zip "$APP"
  rm build/Codec-notarize.zip
fi

STAGING="build/dmg"
rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
ditto "$APP" "$STAGING/Codec.app"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "Codec $VERSION" -srcfolder "$STAGING" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" >/dev/null
rm -rf "$STAGING"

if (( ${#notary[@]} )); then
  codesign --force --timestamp --sign "$IDENTITY" "$DMG"
  notarize "$DMG" "$DMG"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
fi

echo "Built $DMG"
shasum -a 256 "$DMG"
