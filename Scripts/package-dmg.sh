#!/bin/bash
#
# Builds a universal Edge.app and packs it into a drag-to-install disk image.
#
#   Scripts/package-dmg.sh              build, then pack
#   Scripts/package-dmg.sh --no-build   pack the build/Edge.app already there (to work on the look)
#
# Produces, in dist/:
#   Edge.dmg            the stable name the website's download button points at
#   Edge-<version>.dmg  the same image, named for the archive
#   Edge.dmg.sha256     checksum, so a download can be checked
#
# The image holds Edge.app and a shortcut to /Applications, over a background that shows the
# drag and how to get past Gatekeeper the first time (Scripts/make-dmg-background.swift).
# Finder itself arranges the window, so the first run on a Mac asks to let Terminal control
# Finder: click OK.

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"

BUILD=1
for arg in "$@"; do
  case "$arg" in
    --no-build) BUILD=0 ;;
    *) echo "unknown option: $arg" >&2; exit 1 ;;
  esac
done

[ "$BUILD" = 0 ] || Scripts/build.sh --release --universal

APP="$ROOT/build/Edge.app"
[ -d "$APP" ] || { echo "No build/Edge.app — run without --no-build." >&2; exit 1; }
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DIST="$ROOT/dist"
VOLUME="Edge"
MOUNT="/Volumes/$VOLUME"
WORK="$(mktemp -d -t edge-dmg)"
STAGE="$WORK/stage"
RW="$WORK/rw.dmg"
DEVICE=""
cleanup() {
  [ -z "$DEVICE" ] || hdiutil detach -quiet -force "$DEVICE" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

# Keep in step with the layout in Scripts/make-dmg-background.swift.
WIN_W=660; WIN_H=480
EDGE_POS="170, 140"; APPS_POS="490, 140"
ICON_SIZE=112

echo "==> Packing Edge $VERSION"
mkdir -p "$STAGE/.background"
# ditto, not cp: it keeps the extended attributes the code signature depends on.
ditto "$APP" "$STAGE/Edge.app"
ln -s /Applications "$STAGE/Applications"
# The disk's own icon in Finder's sidebar and on the desktop.
cp "$ROOT/Resources/Edge.icns" "$STAGE/.VolumeIcon.icns"
# One TIFF holding the 1x and 2x pictures, so the background is sharp on every display.
swift "$ROOT/Scripts/make-dmg-background.swift" "$WORK/bg"
tiffutil -cathidpicheck "$WORK/bg/background.png" "$WORK/bg/background@2x.png" \
  -out "$STAGE/.background/background.tiff" >/dev/null 2>&1

# Finder finds the disk by name, so nothing else may be mounted as "Edge" — typically an
# Edge.dmg opened earlier.
if [ -e "$MOUNT" ]; then
  hdiutil detach -quiet "$MOUNT" 2>/dev/null \
    || { echo "Another disk is mounted at $MOUNT. Eject it and run this again." >&2; exit 1; }
fi

# Room to spare: Finder has to write the window layout (.DS_Store) into the image.
SIZE_MB=$(( $(du -sm "$STAGE" | cut -f1) + 20 ))
hdiutil create -quiet -volname "$VOLUME" -srcfolder "$STAGE" -fs HFS+ -format UDRW \
  -size "${SIZE_MB}m" -ov "$RW"
DEVICE="$(hdiutil attach -readwrite -noverify -noautoopen "$RW" 2>/dev/null | awk '/Apple_HFS/ { print $1; exit }')"
[ -d "$MOUNT" ] || { echo "The disk image did not mount at $MOUNT." >&2; exit 1; }

# Mark the volume as having a custom icon. SetFile ships with the Command Line Tools; without
# it the disk simply shows the generic icon.
command -v SetFile >/dev/null 2>&1 && SetFile -a C "$MOUNT"

echo "==> Arranging the window"
finder() {
  osascript >/dev/null <<EOF
tell application "Finder"
  tell disk "$VOLUME"
$1
  end tell
end tell
EOF
}
automation_help() {
  echo "Finder could not arrange the disk image window. If macOS asked whether Terminal may" >&2
  echo "control Finder, allow it (System Settings ▸ Privacy & Security ▸ Automation) and run" >&2
  echo "this again." >&2
  exit 1
}

# Pass 1, the window. Its bounds include the title bar, which the background does not cover.
finder "
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, $((200 + WIN_W)), $((120 + WIN_H + 28))}
    set position of item \"Edge.app\" of container window to {$EDGE_POS}
    set position of item \"Applications\" of container window to {$APPS_POS}
    delay 1
    close" || automation_help

# Pass 2, the icon view options. Finder writes these to .DS_Store lazily and sometimes not at
# all on the first try (seen on macOS 27), and detaching before they are written loses them.
# So set them, close the window, and check the file actually has the background; if not, again.
saved() { grep -a backgroundImageAlias "$MOUNT/.DS_Store" >/dev/null 2>&1; }
for _ in 1 2 3 4 5; do
  finder "
    open
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to $ICON_SIZE
    set text size of viewOptions to 13
    set background picture of viewOptions to file \".background:background.tiff\"
    set position of item \"Edge.app\" of container window to {$EDGE_POS}
    set position of item \"Applications\" of container window to {$APPS_POS}
    update without registering applications
    delay 2
    close" || automation_help
  for _ in 1 2 3 4 5; do
    saved && break 2
    sleep 1
  done
done
saved || { echo "Finder never saved the window layout with its background." >&2; exit 1; }
rm -rf "$MOUNT/.fseventsd"
chmod -Rf go-w "$MOUNT" 2>/dev/null || true
sync
hdiutil detach -quiet "$DEVICE" || { sleep 2; hdiutil detach -quiet -force "$DEVICE"; }
DEVICE=""

mkdir -p "$DIST"
OUT="$DIST/Edge-$VERSION.dmg"
rm -f "$OUT"
hdiutil convert -quiet "$RW" -format ULFO -o "$OUT"
cp "$OUT" "$DIST/Edge.dmg"
(cd "$DIST" && shasum -a 256 Edge.dmg > Edge.dmg.sha256)

hdiutil verify -quiet "$OUT"
echo "==> $OUT"
echo "    $DIST/Edge.dmg  ($(du -h "$DIST/Edge.dmg" | cut -f1))"
echo "    sha256 $(cut -d' ' -f1 "$DIST/Edge.dmg.sha256")"
