#!/bin/bash
#
# Builds `edge` and wraps it in Edge.app.
#
# The bundle is not decoration. macOS attributes Accessibility and Input Monitoring grants to
# the *bundle*, so running the bare binary from a terminal would attach those permissions to
# Terminal or iTerm instead — which is both wrong and a much bigger grant than you meant to make.
#
# Usage:
#   Scripts/build.sh            release build + app bundle
#   Scripts/build.sh --debug    debug build + app bundle
#   Scripts/build.sh --install  also symlink `edge` into /usr/local/bin
#   Scripts/build.sh --universal  one app for both Apple silicon and Intel (used for releases)

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"

CONFIG="release"
INSTALL=0
UNIVERSAL=0
for arg in "$@"; do
  case "$arg" in
    --debug)   CONFIG="debug" ;;
    --release) CONFIG="release" ;;
    --install) INSTALL=1 ;;
    --universal) UNIVERSAL=1 ;;
    *) echo "unknown option: $arg" >&2; exit 1 ;;
  esac
done

BUNDLE_ID="app.edge.cli"
APP="$ROOT/build/Edge.app"
ICON="$ROOT/Resources/Edge.icns"
# A self-signed identity created by Scripts/create-signing-identity.sh, if the user made one.
SIGNING_IDENTITY="Edge Local Signing"

# Anything in build/ left over from a previous name. A stale Continuous.app is not inert:
# it holds its own privacy grants, it is what a login item installed before the rename still
# points at, and `continuous` on a PATH keeps running it long after it stopped being the app.
for STALE in "$ROOT"/build/*.app; do
  [ -e "$STALE" ] || continue
  if [ "$STALE" != "$APP" ]; then
    echo "==> Removing $(basename "$STALE") — left over from an earlier name"
    rm -rf "$STALE"
  fi
done
for STALE in "$ROOT"/build/*; do
  [ -f "$STALE" ] && [ -x "$STALE" ] || continue
  if [ "$(basename "$STALE")" != "edge" ]; then
    echo "==> Removing stale launcher $(basename "$STALE")"
    rm -f "$STALE"
  fi
done

# Without Xcode, the default build system hands the linker two Xcode-only search paths that the
# Command Line Tools do not have, and ld warns about each on every link. They are harmless and
# nothing in this package can change them, so exactly those lines are dropped; every other
# warning still shows. sed rather than grep -v: it succeeds on empty output, and pipefail
# still reports a failed build.
quiet_build() {
  swift build "$@" 2>&1 \
    | sed -E "/ld: warning: search path '[^']*CommandLineTools\/Developer\/[^']*' not found/d"
}

if [ "$UNIVERSAL" = "1" ]; then
  # One build per architecture, then lipo. Each gets its own scratch path: the build system
  # writes every triple to the same Products folder, so a second build would silently replace
  # the first one's binaries rather than sit beside them.
  BIN_DIR="$ROOT/.build/universal-$CONFIG"
  rm -rf "$BIN_DIR"
  mkdir -p "$BIN_DIR"
  for ARCH in arm64 x86_64; do
    echo "==> Building ($CONFIG, $ARCH)"
    SCRATCH="$ROOT/.build/arch-$ARCH"
    quiet_build -c "$CONFIG" --triple "$ARCH-apple-macosx13.0" --scratch-path "$SCRATCH"
    ARCH_BIN="$(swift build -c "$CONFIG" --triple "$ARCH-apple-macosx13.0" --scratch-path "$SCRATCH" --show-bin-path)"
    cp "$ARCH_BIN/edge" "$BIN_DIR/edge-$ARCH"
    cp "$ARCH_BIN/EdgeControls" "$BIN_DIR/EdgeControls-$ARCH"
  done
  lipo -create -output "$BIN_DIR/edge" "$BIN_DIR/edge-arm64" "$BIN_DIR/edge-x86_64"
  lipo -create -output "$BIN_DIR/EdgeControls" "$BIN_DIR/EdgeControls-arm64" "$BIN_DIR/EdgeControls-x86_64"
  echo "    $(lipo -archs "$BIN_DIR/edge")"
else
  echo "==> Building ($CONFIG)"
  quiet_build -c "$CONFIG"
  BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
fi
BIN="$BIN_DIR/edge"
CONTROLS_BIN="$BIN_DIR/EdgeControls"
test -x "$BIN" || { echo "build produced no binary at $BIN" >&2; exit 1; }
test -x "$CONTROLS_BIN" || { echo "build produced no binary at $CONTROLS_BIN" >&2; exit 1; }

VERSION="$("$BIN" --version | awk '{print $2}')"
# Stamped into the bundle so `edge --version` can say exactly which commit is running.
# Three fixes for the same bug have now been reported against builds whose provenance was
# unclear; this removes that question.
COMMIT="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
if ! git -C "$ROOT" diff --quiet 2>/dev/null; then COMMIT="$COMMIT+local"; fi
BUILT_AT="$(date -u '+%Y-%m-%d %H:%M UTC')"
# A build number that only ever goes up. Control Center caches what an extension offered under
# its bundle version, so a rebuilt extension with an unchanged version can go on being shown —
# or not shown — as the previous build was. CFBundleVersion only; the version people read
# stays the marketing one.
BUILD_NUMBER="$(date -u '+%Y%m%d%H%M%S')"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/edge"

if [ -f "$ICON" ]; then
  cp "$ICON" "$APP/Contents/Resources/Edge.icns"
else
  echo "    note: no icon at $ICON — run: swift Scripts/make-icon.swift"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>                   <string>Edge</string>
    <key>CFBundleDisplayName</key>            <string>Edge</string>
    <key>CFBundleIdentifier</key>             <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>             <string>edge</string>
    <key>CFBundleIconFile</key>               <string>Edge</string>
    <key>CFBundlePackageType</key>            <string>APPL</string>
    <key>CFBundleShortVersionString</key>     <string>$VERSION</string>
    <key>CFBundleVersion</key>                <string>$BUILD_NUMBER</string>
    <key>EdgeCommit</key>               <string>$COMMIT</string>
    <key>EdgeBuiltAt</key>              <string>$BUILT_AT</string>
    <key>LSMinimumSystemVersion</key>         <string>13.0</string>
    <!-- No Dock icon, no menu bar: this is a background tool driven from the CLI. -->
    <key>LSUIElement</key>                    <true/>
    <key>NSHumanReadableCopyright</key>       <string>Local-only keyboard and mouse sharing. No network destination other than your own paired Mac.</string>
    <key>NSInputMonitoringUsageDescription</key>
        <string>Edge reads keyboard and pointer events so it can forward them to your other Mac.</string>
    <!-- macOS 15 and later gate both Bonjour discovery and outbound connections to LAN
         addresses behind the Local Network permission. Without this key the connection to
         your other Mac fails with no visible error. -->
    <key>NSLocalNetworkUsageDescription</key>
        <string>Edge connects directly to your other Mac on your local network. It never contacts any other server.</string>
    <key>NSBonjourServices</key>
        <array>
            <string>_edge._tcp</string>
            <string>_edge-pair._tcp</string>
        </array>
    <!-- How the Control Center controls reach the app: each one opens an edge-control:// link. -->
    <key>CFBundleURLTypes</key>
        <array>
            <dict>
                <key>CFBundleURLName</key>    <string>$BUNDLE_ID.control</string>
                <key>CFBundleURLSchemes</key> <array><string>edge-control</string></array>
            </dict>
        </array>
</dict>
</plist>
PLIST

# The Control Center controls: a WidgetKit extension, which macOS loads from PlugIns/.
# Its bundle id has to start with the app's, and it only exists from macOS 26 — earlier
# systems see the minimum version and leave it alone.
CONTROLS_ID="$BUNDLE_ID.controls"
APPEX="$APP/Contents/PlugIns/EdgeControls.appex"
mkdir -p "$APPEX/Contents/MacOS" "$APPEX/Contents/Resources/Metadata.appintents"
cp "$CONTROLS_BIN" "$APPEX/Contents/MacOS/EdgeControls"

# What macOS needs to run a tap. Control Center turns the control's intent into an action by
# looking it up in this file; with no entry the tap fails ("action intent without linkAction")
# and the switch does nothing. Xcode generates it with a tool the Command Line Tools do not
# include, so it is written here from Resources/ControlsMetadata.json — modelled on the Dock's
# own auto-hide control — with the intent's mangled type name read out of the binary just
# built, so a rename cannot leave it pointing at a type that no longer exists.
intent_type() {
  local found
  # A universal binary lists every symbol once per architecture, so keep the first. awk rather
  # than head, which can exit early and fail the pipeline with SIGPIPE under pipefail.
  found="$(nm "$CONTROLS_BIN" | sed -n "s/.* _\\\$s\\(12EdgeControls[0-9]*$1V\\)Mn\$/\\1/p" | awk 'NR == 1')"
  if [ -z "$found" ]; then
    echo "could not find EdgeControls.$1 in $CONTROLS_BIN — was it renamed?" >&2
    exit 1
  fi
  echo "$found"
}
POWER_INTENT="$(intent_type PowerIntent)"
OPTIONS_INTENT="$(intent_type OptionsIntent)"
sed -e "s/__POWER_INTENT_TYPE__/$POWER_INTENT/g" -e "s/__OPTIONS_INTENT_TYPE__/$OPTIONS_INTENT/g" \
  "$ROOT/Resources/ControlsMetadata.json" \
  > "$APPEX/Contents/Resources/Metadata.appintents/extract.actionsdata"
cat > "$APPEX/Contents/Resources/Metadata.appintents/version.json" <<JSON
{
  "toolsVersion" : "27A225b",
  "version" : "3.0"
}
JSON
cat > "$APPEX/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>                   <string>Edge Controls</string>
    <key>CFBundleDisplayName</key>            <string>Edge</string>
    <key>CFBundleIdentifier</key>             <string>$CONTROLS_ID</string>
    <key>CFBundleExecutable</key>             <string>EdgeControls</string>
    <key>CFBundlePackageType</key>            <string>XPC!</string>
    <key>CFBundleShortVersionString</key>     <string>$VERSION</string>
    <key>CFBundleVersion</key>                <string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key>         <string>26.0</string>
    <key>NSExtension</key>
        <dict>
            <key>NSExtensionPointIdentifier</key> <string>com.apple.widgetkit-extension</string>
        </dict>
</dict>
</plist>
PLIST

# macOS only loads a sandboxed extension. The one exception lets it read the single file the
# app writes for it (see ControlState.swift) — read-only, and nothing else in your home folder.
ENTITLEMENTS_DIR="$(mktemp -d -t edge-controls)"
CONTROLS_ENTITLEMENTS="$ENTITLEMENTS_DIR/controls.entitlements"
cat > "$CONTROLS_ENTITLEMENTS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key> <true/>
    <key>com.apple.security.temporary-exception.files.home-relative-path.read-only</key>
        <array><string>/Library/Application Support/Edge/</string></array>
</dict>
</plist>
PLIST

# Ad-hoc signature. It gives the bundle a stable code identity on this machine, which is what
# the privacy database keys its grants on. Re-signing after a rebuild changes that identity, so
# a rebuild may require re-ticking the boxes in System Settings — unavoidable without a paid
# Developer ID certificate, and a fair trade for not having to trust anyone else's binary.
# Signing decides whether macOS keeps your privacy permissions across a rebuild.
#
# An ad-hoc signature identifies the app by the hash of its contents, so every rebuild looks
# like a brand new app and Accessibility and Input Monitoring have to be granted again. A
# self-signed certificate gives the bundle a stable identity instead, and the grants stick.
# Scripts/create-signing-identity.sh makes one; this picks it up automatically if it exists.
# Inside out: the extension first, then the app, whose signature seals the extension's in.
sign_all() {
  local identity="$1"
  codesign --force --sign "$identity" --identifier "$CONTROLS_ID" \
           --entitlements "$CONTROLS_ENTITLEMENTS" \
           --options runtime --timestamp=none "$APPEX" &&
  codesign --force --sign "$identity" --identifier "$BUNDLE_ID" \
           --options runtime --timestamp=none "$APP"
}

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGNING_IDENTITY"; then
  echo "==> Signing as \"$SIGNING_IDENTITY\" (stable identity — permissions survive rebuilds)"

  # The first signature with a new key makes the keychain put up a dialog, and codesign then
  # waits for it indefinitely. A build that hangs with no explanation is worse than one that
  # falls back, so give it a deadline and say what to do.
  CODESIGN_LOG="$(mktemp -t edge-codesign)"
  sign_all "$SIGNING_IDENTITY" >"$CODESIGN_LOG" 2>&1 &
  CODESIGN_PID=$!
  WAITED=0
  while kill -0 "$CODESIGN_PID" 2>/dev/null && [ "$WAITED" -lt 20 ]; do
    sleep 1
    WAITED=$((WAITED + 1))
  done

  if kill -0 "$CODESIGN_PID" 2>/dev/null; then
    kill "$CODESIGN_PID" 2>/dev/null || true
    wait "$CODESIGN_PID" 2>/dev/null || true
    echo "    codesign is waiting on a keychain dialog — falling back to ad-hoc."
    echo
    echo "    There is probably a prompt on screen asking whether codesign may use the"
    echo "    key \"$SIGNING_IDENTITY\". Click \"Always Allow\" and build again, or grant it"
    echo "    once from the terminal with your login password:"
    echo
    echo "        security set-key-partition-list -S apple-tool:,apple:,codesign: \\"
    echo "            -s -k \"\$(read -s -p 'login password: ' p; echo \$p)\" \\"
    echo "            ~/Library/Keychains/login.keychain-db"
    echo
    echo "    Or drop the identity entirely:"
    echo "        security delete-certificate -c \"$SIGNING_IDENTITY\""
    echo
    sign_all - 2>&1 | sed 's/^/    /'
  else
    sed 's/^/    /' "$CODESIGN_LOG"
  fi
  rm -f "$CODESIGN_LOG"
else
  echo "==> Signing (ad-hoc)"
  sign_all - 2>&1 | sed 's/^/    /'
  echo
  echo "    ⚠ No stable signing identity on this Mac."
  echo "      An ad-hoc signature identifies the app by the hash of its contents, so every"
  echo "      rebuild looks like a brand new app and you will be asked for Accessibility and"
  echo "      Input Monitoring again each time. Run this once to stop that:"
  echo
  echo "          Scripts/create-signing-identity.sh"
  echo
fi
rm -rf "$ENTITLEMENTS_DIR"
codesign --verify --strict --verbose=1 "$APP" 2>&1 | sed 's/^/    /'

# Tell Launch Services about this copy now, so the controls show up in Control Center's
# gallery and edge-control:// links reach it, without first having to open the app by hand.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
[ -x "$LSREGISTER" ] && "$LSREGISTER" -f "$APP" >/dev/null 2>&1 || true
# Launch Services hands the extension on to the plug-in registry in its own time, and after a
# rebuild that sometimes means not at all until the app is next opened. Ask directly.
pluginkit -a "$APPEX" >/dev/null 2>&1 || true
# A controls process from the previous build keeps answering Control Center with the old code
# until something stops it. macOS starts the new one the next time it is needed.
pkill -x EdgeControls >/dev/null 2>&1 || true

# A tiny launcher so `edge` on your PATH runs the *bundled* copy, keeping one code
# identity and therefore one set of permission grants.
mkdir -p "$ROOT/build"
cat > "$ROOT/build/edge" <<LAUNCHER
#!/bin/bash
exec "$APP/Contents/MacOS/edge" "\$@"
LAUNCHER
chmod +x "$ROOT/build/edge"

echo "==> Built $APP  (commit $COMMIT)"
echo "    binary  $(du -h "$APP/Contents/MacOS/edge" | cut -f1)"
echo "    launcher $ROOT/build/edge"

if [ "$INSTALL" = "1" ]; then
  DEST="/usr/local/bin/edge"
  echo "==> Installing launcher to $DEST"
  if [ -w "$(dirname "$DEST")" ]; then
    ln -sf "$ROOT/build/edge" "$DEST"
  else
    sudo ln -sf "$ROOT/build/edge" "$DEST"
  fi
  echo "    $DEST -> $ROOT/build/edge"
fi

echo
echo "Next:"
echo "    $ROOT/build/edge selftest"
echo "    $ROOT/build/edge doctor"
