#!/usr/bin/env bash
# Points the Homebrew cask at a release's disk image. Usage: scripts/update-cask.sh <version> <dmg>
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?Usage: scripts/update-cask.sh <version> <dmg>}"
VERSION="${VERSION#v}"
DMG="${2:?Usage: scripts/update-cask.sh <version> <dmg>}"
SHA="$(shasum -a 256 "$DMG" | cut -d ' ' -f 1)"
CASK="Casks/codec.rb"

sed -i '' -E \
  -e "s/^  version \".*\"$/  version \"$VERSION\"/" \
  -e "s/^  sha256 .*$/  sha256 \"$SHA\"/" \
  "$CASK"
grep -q "version \"$VERSION\"" "$CASK" && grep -q "sha256 \"$SHA\"" "$CASK"
echo "$CASK now installs Codec $VERSION ($SHA)"
