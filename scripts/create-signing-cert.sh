#!/usr/bin/env bash
# Create a self-signed code-signing certificate named "Frost Local Signing" and import it into the login keychain.
# Purpose: keep the signing identity stable across rebuilds so macOS doesn't keep asking to re-grant
# Accessibility / Screen Recording permissions.
set -euo pipefail
# shellcheck source=scripts/lib/openssl.sh
source "$(dirname "$0")/lib/openssl.sh"
NAME="Frost Local Signing"
if security find-identity -p codesigning | grep -q "$NAME"; then
  echo "Identity '$NAME' already exists."; exit 0
fi
OPENSSL=$(find_openssl) || { echo "OpenSSL 3 is required (brew install openssl@3)" >&2; exit 1; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cert.cnf" <<EOF
[ req ]
distinguished_name = dn
x509_extensions = ext
prompt = no
[ dn ]
CN = $NAME
[ ext ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF
"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cnf"
"$OPENSSL" pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/cert.p12" -passout pass:frost -name "$NAME"
security import "$TMP/cert.p12" -k ~/Library/Keychains/login.keychain-db -P frost -T /usr/bin/codesign
echo "Imported. If codesign reports the identity is not trusted, open Keychain Access →"
echo "'$NAME' → Trust → Code Signing: Always Trust."
security find-identity -p codesigning | grep "$NAME"
