#!/bin/zsh
# Retakes the screenshots in docs/images (see Tests/CodecUITests/ScreenshotTour.swift). Windows open
# on screen while it runs. Everything happens in a throwaway home folder, so none of your history,
# Intel or files show.
set -euo pipefail
cd "${0:A:h}/.."
# Under .build, which is ignored, and on a path without symlinks, so ~ abbreviates it everywhere.
home="$PWD/.build/screenshot-home"
rm -rf "$home"
mkdir -p "$home"
trap 'rm -rf "$home"' EXIT
swift build -j "${JOBS:-2}" --build-tests
CODEC_SCREENSHOTS="$PWD/docs/images" HOME="$home" CFFIXED_USER_HOME="$home" \
  swift test -j "${JOBS:-2}" --skip-build --filter ScreenshotTour
