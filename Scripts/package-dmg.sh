#!/bin/bash
#
# Builds a universal Edge.app and packs it into a drag-to-install disk image.
#
#   Scripts/package-dmg.sh
#
# Produces, in dist/:
#   Edge.dmg            the stable name the website's download button points at
#   Edge-<version>.dmg  the same image, named for the archive
#   Edge.dmg.sha256     checksum, so a download can be checked
#
# The image holds Edge.app and a shortcut to /Applications — open it, drag one onto the other.

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"

Scripts/build.sh --release --universal

APP="$ROOT/build/Edge.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DIST="$ROOT/dist"
STAGE="$(mktemp -d -t edge-dmg)"
trap 'rm -rf "$STAGE"' EXIT

echo "==> Packing Edge $VERSION"
# ditto, not cp: it keeps the extended attributes the code signature depends on.
ditto "$APP" "$STAGE/Edge.app"
ln -s /Applications "$STAGE/Applications"
# The disk's own icon in Finder's sidebar and on the desktop.
cp "$ROOT/Resources/Edge.icns" "$STAGE/.VolumeIcon.icns"

mkdir -p "$DIST"
RW="$STAGE.rw.dmg"
rm -f "$RW"
hdiutil create -quiet -volname "Edge" -srcfolder "$STAGE" -fs HFS+ -format UDRW -ov "$RW"
# Mark the volume as having a custom icon. SetFile ships with the Command Line Tools; without
# it the disk simply shows the generic icon.
if command -v SetFile >/dev/null 2>&1; then
  MOUNT="$(mktemp -d -t edge-mount)"
  hdiutil attach -quiet -nobrowse -noautoopen -mountpoint "$MOUNT" "$RW"
  SetFile -a C "$MOUNT"
  hdiutil detach -quiet "$MOUNT"
  rmdir "$MOUNT" 2>/dev/null || true
fi

OUT="$DIST/Edge-$VERSION.dmg"
rm -f "$OUT"
hdiutil convert -quiet "$RW" -format ULFO -o "$OUT"
rm -f "$RW"
cp "$OUT" "$DIST/Edge.dmg"
(cd "$DIST" && shasum -a 256 Edge.dmg > Edge.dmg.sha256)

hdiutil verify -quiet "$OUT"
echo "==> $OUT"
echo "    $DIST/Edge.dmg  ($(du -h "$DIST/Edge.dmg" | cut -f1))"
echo "    sha256 $(cut -d' ' -f1 "$DIST/Edge.dmg.sha256")"
