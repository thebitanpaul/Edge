#!/bin/bash
#
# Publishes dist/ to the GitHub release for the version in build/Edge.app, and marks it Latest.
#
# Normally you don't run this yourself: Scripts/release.sh does the whole release and calls it.
# By hand:
#   Scripts/package-dmg.sh                         # build dist/ first
#   Scripts/publish-release.sh [--notes FILE]      # then publish it
#
# Creates the release if the tag has none yet, or updates it if it does. Any asset with the
# same name is deleted and uploaded again, so re-running this after a rebuild replaces the files
# rather than failing. FILE, if given, is Markdown placed above the standard install notes.
#
# Authentication: $GITHUB_TOKEN if set, otherwise the GitHub credential git already uses
# (the macOS keychain). The token is never printed.

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
. "$ROOT/Scripts/lib/release-common.sh"

NOTES=""
while [ $# -gt 0 ]; do
  case "$1" in
    --notes) NOTES="$2"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

APP="$ROOT/build/Edge.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
TAG="v$VERSION"
ASSETS=(Edge.dmg "Edge-$VERSION.dmg" Edge.dmg.sha256)
for f in "${ASSETS[@]}"; do
  [ -f "$ROOT/dist/$f" ] || { echo "dist/$f is missing — run Scripts/package-dmg.sh first." >&2; exit 1; }
done

# Refuse to publish something the users' Macs would not recognise as the same app. By
# fingerprint, not by name: any Mac can make a certificate called "Edge Local Signing".
if ! signed_by_pinned_cert "$APP"; then
  echo "build/Edge.app is not signed with the release \"$SIGNING_NAME\" certificate" >&2
  echo "(ad-hoc fallback, or a different certificate with the same name)." >&2
  echo "Publishing it would make every user grant permissions again. Fix signing and rebuild." >&2
  exit 1
fi

# The release must point at a tag GitHub already has, or GitHub would invent one from main.
if [ -z "$(git ls-remote origin "refs/tags/$TAG")" ]; then
  echo "Tag $TAG is not on GitHub yet. Run:" >&2
  echo "    git tag -a $TAG -m \"Edge $VERSION\" && git push origin $TAG" >&2
  exit 1
fi

TOKEN="$(github_token)"
[ -n "$TOKEN" ] || { echo "No GitHub token: set GITHUB_TOKEN or sign git in to GitHub." >&2; exit 1; }

TMP="$(mktemp -d -t edge-release)"
trap 'rm -rf "$TMP"' EXIT
gh_api() { curl -sS -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" "$@"; }
json() { python3 -I -c "import json,sys; d=json.load(open(sys.argv[1])); $1" "$2"; }

SHA="$(cut -d' ' -f1 "$ROOT/dist/Edge.dmg.sha256")"
# The notes go above the "### Download" heading. .github/scripts/sync_release_notes.py finds
# where the notes end by that heading when it updates a release, so keep it.
python3 -I - "$VERSION" "$SHA" "$NOTES" > "$TMP/body.json" <<'EOF'
import json, sys
version, sha, notes_path = sys.argv[1:4]
notes = open(notes_path).read().strip() + "\n\n" if notes_path else ""
body = f"""{notes}### Download
**[Edge.dmg](https://github.com/thebitanpaul/Edge/releases/latest/download/Edge.dmg)** — universal (Apple silicon + Intel), macOS 13 Ventura or later.

### Install
1. Open `Edge.dmg` and drag **Edge** onto **Applications** — on both Macs.
2. Open Edge. macOS will say it can't verify the developer (Edge is open source and not notarised by Apple): go to **System Settings ▸ Privacy & Security** and click **Open Anyway**.
3. Grant Accessibility (both Macs) and Input Monitoring (the primary), then choose **Set up** on both.

### Checksum
```
SHA-256 (Edge.dmg) = {sha}
```
"""
print(json.dumps({"tag_name": f"v{version}", "name": f"Edge {version}", "body": body,
                  "draft": False, "prerelease": False, "make_latest": "true"}))
EOF

gh_api -o "$TMP/existing.json" -w '%{http_code}' "$API/releases/tags/$TAG" > "$TMP/status"
if [ "$(cat "$TMP/status")" = "200" ]; then
  RID="$(json 'print(d["id"])' "$TMP/existing.json")"
  echo "==> Updating release $TAG"
  gh_api -X PATCH "$API/releases/$RID" --data-binary @"$TMP/body.json" > "$TMP/release.json"
else
  echo "==> Creating release $TAG"
  gh_api -X POST "$API/releases" --data-binary @"$TMP/body.json" > "$TMP/release.json"
fi
RID="$(json 'print(d.get("id", ""))' "$TMP/release.json")"
if [ -z "$RID" ]; then echo "GitHub refused the release:" >&2; cat "$TMP/release.json" >&2; exit 1; fi

for f in "${ASSETS[@]}"; do
  OLD="$(json "print(next((a['id'] for a in d.get('assets', []) if a['name'] == '$f'), ''))" "$TMP/release.json")"
  if [ -n "$OLD" ]; then
    gh_api -X DELETE "$API/releases/assets/$OLD" >/dev/null
    echo "    removed old $f"
  fi
  CT=application/x-apple-diskimage
  [ "$f" = Edge.dmg.sha256 ] && CT=text/plain
  gh_api -X POST -H "Content-Type: $CT" --data-binary @"$ROOT/dist/$f" \
    "https://uploads.github.com/repos/$REPO/releases/$RID/assets?name=$f" > "$TMP/asset.json"
  echo "    uploaded $(json 'print(d.get("name"), d.get("size"), "bytes", d.get("message", ""))' "$TMP/asset.json")"
done

echo "==> https://github.com/$REPO/releases/tag/$TAG"
echo "    Download link: https://github.com/$REPO/releases/latest/download/Edge.dmg"
