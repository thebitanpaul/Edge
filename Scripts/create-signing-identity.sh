#!/bin/bash
#
# Creates a self-signed code-signing certificate so Continuous.app keeps a stable identity.
#
# Why you want this: macOS keys Accessibility and Input Monitoring grants to an app's code
# identity. With an ad-hoc signature that identity is the hash of the app's contents, so every
# rebuild looks like a different app and you have to grant both permissions again. A
# self-signed certificate gives the bundle one identity that survives rebuilds.
#
# The certificate is yours, lives in your login keychain, is trusted by nothing except your own
# Mac, and can be removed at any time:
#
#     security delete-certificate -c "Continuous Local Signing"
#
# Run once:   Scripts/create-signing-identity.sh

set -euo pipefail

NAME="Continuous Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$NAME"; then
  echo "✓ '$NAME' already exists — nothing to do."
  echo "  Scripts/build.sh will use it automatically."
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> Generating a self-signed code-signing certificate"
# basicConstraints CA:false and the codeSigning EKU are what make codesign accept it.
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
  -subj "/CN=$NAME/O=Continuous/C=US" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null

openssl pkcs12 -export -out "$WORK/identity.p12" \
  -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -name "$NAME" -passout pass: 2>/dev/null

echo "==> Importing into your login keychain"
# -T /usr/bin/codesign lets codesign use the key without prompting on every build.
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "" \
  -T /usr/bin/codesign -T /usr/bin/security

echo "==> Marking it trusted for code signing"
# Trust settings live in the login keychain, so this is a user-level change and needs no sudo.
# It may ask for your login password once.
security add-trusted-cert -d -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem" \
  2>/dev/null || echo "    (trust step skipped — signing usually works regardless)"

# Stop the keychain prompting for the key on every single build.
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "" "$KEYCHAIN" >/dev/null 2>&1 \
  || true

echo
if security find-identity -v -p codesigning | grep -q "$NAME"; then
  echo "✓ '$NAME' is ready."
  echo
  echo "Next:"
  echo "    Scripts/build.sh"
  echo
  echo "You will be asked for Accessibility and Input Monitoring one more time,"
  echo "because the app's identity has just changed. After that they will stick."
else
  echo "✗ The identity was not created. Scripts/build.sh will fall back to ad-hoc signing."
  exit 1
fi
