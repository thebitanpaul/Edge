#!/bin/bash
#
# Creates a self-signed code-signing certificate so Edge.app keeps a stable identity.
#
# Why you want this: macOS keys Accessibility and Input Monitoring grants to an app's code
# identity. With an ad-hoc signature that identity is a hash of the app's contents, so every
# rebuild looks like a different app and you have to grant both permissions again. A
# self-signed certificate gives the bundle one identity that survives rebuilds.
#
# The certificate is yours, lives in your login keychain, is trusted by nothing except your own
# Mac, and can be removed at any time:
#
#     security delete-certificate -c "Edge Local Signing"
#
# Usage:  Scripts/create-signing-identity.sh [--keychain PATH]

set -euo pipefail

NAME="Edge Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

while [ $# -gt 0 ]; do
  case "$1" in
    --keychain) KEYCHAIN="$2"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$NAME"; then
  echo "✓ '$NAME' already exists — nothing to do."
  echo "  Scripts/build.sh will use it automatically."
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> Generating a self-signed code-signing certificate"
# The common name is what `codesign -s` matches on, so it has to be exactly $NAME.
# basicConstraints CA:false and the codeSigning EKU are what make codesign accept it at all.
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
  -subj "/CN=$NAME/O=Edge" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null

# Two things will break this bundle if you let them.
#
# An *empty* password produces a PKCS#12 that macOS refuses with
#   "MAC verification failed during PKCS12 import (wrong password?)"
# which reads like the password is wrong when the real problem is that there isn't one. So the
# bundle gets a random password that exists only for the next three lines.
#
# OpenSSL 3 also defaults to a SHA-256 MAC and AES encryption, which the Security framework
# cannot read. `-legacy` asks for the older algorithms it does understand. LibreSSL — what
# /usr/bin/openssl is on a stock macOS — has no such flag and does not need one.
PW="$(openssl rand -hex 24)"
# Written as two whole commands rather than an array of flags: macOS ships bash 3.2, where
# expanding an *empty* array under `set -u` is itself an error — which is how this line read
# "LEGACY[@]: unbound variable" on exactly the machines that did not need the flag.
if openssl pkcs12 -help 2>&1 | grep -q -- -legacy; then
  openssl pkcs12 -export -legacy -out "$WORK/identity.p12" \
    -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -name "$NAME" -passout "pass:$PW" 2>/dev/null
else
  openssl pkcs12 -export -out "$WORK/identity.p12" \
    -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -name "$NAME" -passout "pass:$PW" 2>/dev/null
fi

echo "==> Importing into the keychain"
# -T lets codesign use the private key without a prompt on every single build.
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$PW" \
  -T /usr/bin/codesign -T /usr/bin/security >/dev/null

echo "==> Trusting it for code signing"
# User trust domain, not system: no administrator password, and the trust applies to you only.
# Without this the identity imports but `codesign` reports CSSMERR_TP_NOT_TRUSTED.
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem" 2>/dev/null \
  || echo "    (could not set trust automatically — see the note below if signing fails)"

# Stop the keychain prompting for the key on every build.
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "" "$KEYCHAIN" >/dev/null 2>&1 \
  || true

echo
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$NAME"; then
  echo "✓ '$NAME' is ready."
  echo
  echo "Next:"
  echo "    Scripts/build.sh"
  echo
  echo "You will be asked for Accessibility and Input Monitoring one more time,"
  echo "because the app's identity has just changed. After that they will stick."
else
  echo "✗ The identity is not usable for signing yet."
  echo "  It was imported, but macOS does not trust it for code signing."
  echo "  Open Keychain Access, find \"$NAME\", get info, and under Trust set"
  echo "  \"Code Signing\" to \"Always Trust\". Then run Scripts/build.sh."
  echo
  echo "  Scripts/build.sh falls back to ad-hoc signing until then, which works —"
  echo "  it just means re-granting permissions after each rebuild."
  exit 1
fi
