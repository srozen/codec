#!/usr/bin/env bash
# Publishes a release's disk image to codec.srozen.com, where the website and Codec's updates get it.
# Usage: scripts/publish-release.sh <version> <dmg>
#
# The disk image goes to the codec-releases R2 bucket, which the website serves at /releases/. Then,
# unless the version is a prerelease (it has a "-"), latest.json says it's the newest: Codec reads it
# to look for updates, and /download redirects to its disk image. It's written in the shape of GitHub's
# releases API, with the notes of the release on GitHub, which has to exist already.
#
# Uploads go through R2's S3 API, signed by curl, with an R2 API token limited to Object Read & Write on
# codec-releases: R2_ACCESS_KEY_ID and R2_SECRET_ACCESS_KEY, plus CLOUDFLARE_ACCOUNT_ID for the
# endpoint. Such a key can't touch any other bucket in the account. gh's credentials read the notes.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?Usage: scripts/publish-release.sh <version> <dmg>}"
VERSION="${VERSION#v}"
DMG="${2:?Usage: scripts/publish-release.sh <version> <dmg>}"
TAG="v$VERSION"
SITE="https://codec.srozen.com"
BUCKET="codec-releases"
NAME="Codec-$VERSION.dmg"
: "${R2_ACCESS_KEY_ID:?Set R2_ACCESS_KEY_ID and R2_SECRET_ACCESS_KEY to an R2 API token for $BUCKET}"
: "${R2_SECRET_ACCESS_KEY:?Set R2_ACCESS_KEY_ID and R2_SECRET_ACCESS_KEY to an R2 API token for $BUCKET}"
: "${CLOUDFLARE_ACCOUNT_ID:?Set CLOUDFLARE_ACCOUNT_ID to the Cloudflare account that has $BUCKET}"
ENDPOINT="https://$CLOUDFLARE_ACCOUNT_ID.r2.cloudflarestorage.com/$BUCKET"

# put <file> <key> <content type> <cache control> [content disposition]
# Signs the request with the file's SHA-256, which R2 checks against what arrives. The keys reach curl
# on its standard input, not its arguments, which any process on the machine can read.
put() {
  local hash
  hash="$(shasum -a 256 "$1" | cut -d ' ' -f 1)"
  local headers=(-H "Content-Type: $3" -H "Cache-Control: $4" -H "x-amz-content-sha256: $hash")
  [[ -n "${5:-}" ]] && headers+=(-H "Content-Disposition: $5")
  printf 'user = "%s:%s"\n' "$R2_ACCESS_KEY_ID" "$R2_SECRET_ACCESS_KEY" \
    | curl --config - --fail-with-body --silent --show-error --retry 3 --aws-sigv4 "aws:amz:auto:s3" \
        "${headers[@]}" --upload-file "$1" "$ENDPOINT/$2"
}

SHA="$(shasum -a 256 "$DMG" | cut -d ' ' -f 1)"
SIZE="$(wc -c < "$DMG" | tr -d ' ')"

# A version's disk image never changes once it's out, so it can be cached for good.
put "$DMG" "$NAME" application/x-apple-diskimage "public, max-age=31536000, immutable" \
  "attachment; filename=\"$NAME\""
echo "Uploaded $SITE/releases/$NAME ($SHA)"

if [[ "$VERSION" == *-* ]]; then
  echo "$VERSION is a prerelease: latest.json still names the release before it"
  exit 0
fi

LATEST="$(mktemp)"
trap 'rm -f "$LATEST"' EXIT
gh release view "$TAG" --json tagName,name,body,url,publishedAt \
  | jq --arg name "$NAME" --arg url "$SITE/releases/$NAME" --arg digest "sha256:$SHA" --argjson size "$SIZE" '{
      tag_name: .tagName,
      name: .name,
      body: .body,
      html_url: .url,
      published_at: .publishedAt,
      assets: [{name: $name, browser_download_url: $url, digest: $digest, size: $size,
                content_type: "application/x-apple-diskimage"}]
    }' > "$LATEST"

# Uploaded after the disk image, so it never names one that isn't there yet.
put "$LATEST" latest.json "application/json; charset=utf-8" "public, max-age=300"
echo "$SITE/releases/latest.json now names Codec $VERSION"
