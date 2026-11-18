# Shared by Scripts/release.sh and Scripts/publish-release.sh. Sourced, not run.
#
# Who can publish an Edge release is decided by two things these scripts check but cannot
# hand out: the private key of the "Edge Local Signing" certificate (backed up as
# edge-signing.p12), and a GitHub login with push access to thebitanpaul/Edge.
#
# Matching the certificate by name is not enough — Scripts/create-signing-identity.sh makes
# a certificate with the same name on any Mac. So the release one is pinned by fingerprint.
# The fingerprint is of the public certificate, which is inside every released Edge.app
# anyway; it is not a secret, and knowing it does not let anyone sign as it.

REPO="thebitanpaul/Edge"
API="https://api.github.com/repos/$REPO"
SIGNING_NAME="Edge Local Signing"
SIGNING_SHA256="C1CADC3C99818478533684890B2F6D6C87CD8CD47743F63F6B5C7CEAC60B273E"

# SHA-1 of the pinned certificate if any keychain holds it (with or without its key).
pinned_cert_sha1() {
  security find-certificate -a -c "$SIGNING_NAME" -Z 2>/dev/null | awk -v want="$SIGNING_SHA256" '
    /^SHA-256 hash:/ { s = $3 }
    /^SHA-1 hash:/   { if (s == want) { print $3; exit } s = "" }'
}

# SHA-1 of the pinned certificate if it is a usable code-signing identity: certificate,
# private key, and trusted for code signing. Empty otherwise. codesign accepts the SHA-1 in
# place of the name, which also sidesteps any look-alike with the same name.
pinned_identity_sha1() {
  local sha1
  sha1="$(pinned_cert_sha1)"
  [ -n "$sha1" ] || return 0
  if security find-identity -v -p codesigning 2>/dev/null | grep -F "$sha1" >/dev/null; then
    echo "$sha1"
  fi
}

# Succeeds if the signature on $1 is valid and its leaf certificate is the pinned one.
signed_by_pinned_cert() {
  local dir got=""
  codesign --verify --strict "$1" >/dev/null 2>&1 || return 1
  dir="$(mktemp -d -t edge-cert)"
  (cd "$dir" && codesign -d --extract-certificates=cert "$1" >/dev/null 2>&1) || true
  [ -f "$dir/cert0" ] && got="$(shasum -a 256 "$dir/cert0" | cut -d' ' -f1 | tr '[:lower:]' '[:upper:]')"
  rm -rf "$dir"
  [ "$got" = "$SIGNING_SHA256" ]
}

# $GITHUB_TOKEN if set, otherwise the GitHub credential git already uses (macOS keychain).
github_token() {
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    printf '%s' "$GITHUB_TOKEN"
  else
    printf 'protocol=https\nhost=github.com\n\n' | git credential fill 2>/dev/null | sed -n 's/^password=//p'
  fi
}
