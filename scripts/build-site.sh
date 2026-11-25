#!/usr/bin/env bash
# Puts Codec's website together in build/site: the pages in site/, with docs/images as its images, so
# the website and the README show the same screenshots. Usage:
#   scripts/build-site.sh            build it
#   scripts/build-site.sh --deploy   build it and deploy it to Cloudflare Pages, after
#                                    `npx wrangler login`
# To see it with its functions, which serve /releases/ from a local bucket: cd build/site && npx
# wrangler pages dev.
set -euo pipefail
cd "$(dirname "$0")/.."

WRANGLER="wrangler@4.150.0"
OUT="build/site"

rm -rf "$OUT"
mkdir -p build
cp -R site "$OUT"
mkdir -p "$OUT/public/images"
# Only the images the pages show; app-icon.png is drawn below.
for image in $(grep -oh 'images/[A-Za-z0-9_-]*\.png' site/public/*.html | sort -u); do
  image="docs/$image"
  [[ -f "$image" ]] || continue
  # Screenshots are taken at twice their size; 2000 pixels wide is plenty on a web page.
  width="$(command -v sips >/dev/null && sips -g pixelWidth "$image" | awk '/pixelWidth/ { print $2 }' || echo 0)"
  if (( width > 2000 )); then
    sips --resampleWidth 2000 "$image" --out "$OUT/public/images/" >/dev/null
  else
    cp "$image" "$OUT/public/images/"
  fi
done
# The hero shows the app's icon large; drawn as the app's is, or the README's copy without Swift.
if command -v swift >/dev/null && command -v sips >/dev/null; then
  swift scripts/make-icon.swift build/site-icon.png >/dev/null
  sips --resampleWidth 512 build/site-icon.png --out "$OUT/public/images/app-icon.png" >/dev/null
  rm build/site-icon.png
else
  cp docs/images/icon.png "$OUT/public/images/app-icon.png"
fi
echo "Built $OUT"

if [[ "${1:-}" == "--deploy" ]]; then
  cd "$OUT"
  npx --yes "$WRANGLER" pages deploy --project-name codec --branch main --commit-dirty=true
fi
