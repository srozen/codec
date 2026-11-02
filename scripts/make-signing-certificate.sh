#!/usr/bin/env bash
# Makes the self-signed certificate Codec's releases are signed with, so every version has the same
# identity: macOS then keeps the permissions people gave Codec (Full Disk Access, the camera,
# controlling other apps) when they update. It doesn't make Gatekeeper trust Codec: only Apple's
# notarization does that.
#
# Usage: scripts/make-signing-certificate.sh [--github] [folder]
#   folder    where to keep the certificate and its key, readable only by you; default ~/.codec-signing
#   --github  also store them as this repository's SIGNING_CERTIFICATE and SIGNING_CERTIFICATE_PASSWORD
#             secrets, with gh
#
# Keep the folder (a backup, a password manager): a new certificate is a new identity, and everyone
# would grant Codec its permissions once more.
set -euo pipefail
cd "$(dirname "$0")/.."

GITHUB=0
if [[ "${1:-}" == "--github" ]]; then GITHUB=1; shift; fi
DIR="${1:-$HOME/.codec-signing}"
NAME="Codec Release Signing"
P12="$DIR/codec-signing.p12"
PASSWORD_FILE="$DIR/codec-signing.password"
# macOS's LibreSSL, whose PKCS#12 files `security import` reads.
OPENSSL=/usr/bin/openssl

if [[ -e "$P12" ]]; then
  echo "$P12 already exists: Codec keeps its identity only as long as it keeps this certificate." >&2
  echo "Delete it first if you really mean to replace it." >&2
  [[ $GITHUB == 1 ]] || exit 1
  echo "Storing the existing one in GitHub instead." >&2
else
  mkdir -p "$DIR"
  chmod 700 "$DIR"
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' EXIT
  cat > "$work/certificate.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF
  # Twenty years: the identity is meant to outlast Codec's versions.
  "$OPENSSL" req -x509 -newkey rsa:3072 -nodes -days 7300 -config "$work/certificate.cnf" \
    -keyout "$work/key.pem" -out "$work/certificate.pem" 2>/dev/null
  # No newline: the file is the secret, byte for byte.
  (umask 077 && printf '%s' "$("$OPENSSL" rand -hex 24)" > "$PASSWORD_FILE")
  (umask 077 && "$OPENSSL" pkcs12 -export -name "$NAME" -inkey "$work/key.pem" -in "$work/certificate.pem" \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
    -passout file:"$PASSWORD_FILE" -out "$P12")
  echo "Made \"$NAME\" in $DIR"
  "$OPENSSL" x509 -in "$work/certificate.pem" -noout -fingerprint -sha1 | sed 's/^/  /'
fi

if [[ $GITHUB == 1 ]]; then
  base64 -i "$P12" | gh secret set SIGNING_CERTIFICATE
  gh secret set SIGNING_CERTIFICATE_PASSWORD < "$PASSWORD_FILE"
  echo "Stored SIGNING_CERTIFICATE and SIGNING_CERTIFICATE_PASSWORD in GitHub: the next release is signed with it."
else
  echo "To sign releases with it: scripts/make-signing-certificate.sh --github $DIR"
fi
