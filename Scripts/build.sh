#!/bin/bash
#
# Builds `continuous` and wraps it in Continuous.app.
#
# The bundle is not decoration. macOS attributes Accessibility and Input Monitoring grants to
# the *bundle*, so running the bare binary from a terminal would attach those permissions to
# Terminal or iTerm instead — which is both wrong and a much bigger grant than you meant to make.
#
# Usage:
#   Scripts/build.sh            release build + app bundle
#   Scripts/build.sh --debug    debug build + app bundle
#   Scripts/build.sh --install  also symlink `continuous` into /usr/local/bin

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"

CONFIG="release"
INSTALL=0
for arg in "$@"; do
  case "$arg" in
    --debug)   CONFIG="debug" ;;
    --release) CONFIG="release" ;;
    --install) INSTALL=1 ;;
    *) echo "unknown option: $arg" >&2; exit 1 ;;
  esac
done

BUNDLE_ID="app.continuous.cli"
APP="$ROOT/build/Continuous.app"
ICON="$ROOT/Resources/Continuous.icns"
# A self-signed identity created by Scripts/create-signing-identity.sh, if the user made one.
SIGNING_IDENTITY="Continuous Local Signing"

echo "==> Building ($CONFIG)"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/continuous"
test -x "$BIN" || { echo "build produced no binary at $BIN" >&2; exit 1; }

VERSION="$("$BIN" --version | awk '{print $2}')"
# Stamped into the bundle so `continuous --version` can say exactly which commit is running.
# Three fixes for the same bug have now been reported against builds whose provenance was
# unclear; this removes that question.
COMMIT="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
if ! git -C "$ROOT" diff --quiet 2>/dev/null; then COMMIT="$COMMIT+local"; fi
BUILT_AT="$(date -u '+%Y-%m-%d %H:%M UTC')"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/continuous"

if [ -f "$ICON" ]; then
  cp "$ICON" "$APP/Contents/Resources/Continuous.icns"
else
  echo "    note: no icon at $ICON — run: swift Scripts/make-icon.swift"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>                   <string>Continuous</string>
    <key>CFBundleDisplayName</key>            <string>Continuous</string>
    <key>CFBundleIdentifier</key>             <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>             <string>continuous</string>
    <key>CFBundleIconFile</key>               <string>Continuous</string>
    <key>CFBundlePackageType</key>            <string>APPL</string>
    <key>CFBundleShortVersionString</key>     <string>$VERSION</string>
    <key>CFBundleVersion</key>                <string>$VERSION</string>
    <key>ContinuousCommit</key>               <string>$COMMIT</string>
    <key>ContinuousBuiltAt</key>              <string>$BUILT_AT</string>
    <key>LSMinimumSystemVersion</key>         <string>13.0</string>
    <!-- No Dock icon, no menu bar: this is a background tool driven from the CLI. -->
    <key>LSUIElement</key>                    <true/>
    <key>NSHumanReadableCopyright</key>       <string>Local-only keyboard and mouse sharing. No network destination other than your own paired Mac.</string>
    <key>NSInputMonitoringUsageDescription</key>
        <string>Continuous reads keyboard and pointer events so it can forward them to your other Mac.</string>
    <!-- macOS 15 and later gate both Bonjour discovery and outbound connections to LAN
         addresses behind the Local Network permission. Without this key the connection to
         your other Mac fails with no visible error. -->
    <key>NSLocalNetworkUsageDescription</key>
        <string>Continuous connects directly to your other Mac on your local network. It never contacts any other server.</string>
    <key>NSBonjourServices</key>
        <array>
            <string>_continuous._tcp</string>
        </array>
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
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGNING_IDENTITY"; then
  echo "==> Signing as \"$SIGNING_IDENTITY\" (stable identity — permissions survive rebuilds)"

  # The first signature with a new key makes the keychain put up a dialog, and codesign then
  # waits for it indefinitely. A build that hangs with no explanation is worse than one that
  # falls back, so give it a deadline and say what to do.
  codesign --force --sign "$SIGNING_IDENTITY" --identifier "$BUNDLE_ID" \
           --options runtime --timestamp=none "$APP" >/tmp/continuous-codesign.log 2>&1 &
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
    codesign --force --sign - --identifier "$BUNDLE_ID" --timestamp=none "$APP" 2>&1 | sed 's/^/    /'
  else
    sed 's/^/    /' /tmp/continuous-codesign.log
  fi
  rm -f /tmp/continuous-codesign.log
else
  echo "==> Signing (ad-hoc)"
  codesign --force --sign - --identifier "$BUNDLE_ID" --timestamp=none "$APP" 2>&1 | sed 's/^/    /'
  echo "    note: every rebuild changes this app's identity, so macOS will ask for"
  echo "          Accessibility and Input Monitoring again. To stop that happening:"
  echo "              Scripts/create-signing-identity.sh"
fi
codesign --verify --verbose=1 "$APP" 2>&1 | sed 's/^/    /'

# A tiny launcher so `continuous` on your PATH runs the *bundled* copy, keeping one code
# identity and therefore one set of permission grants.
mkdir -p "$ROOT/build"
cat > "$ROOT/build/continuous" <<LAUNCHER
#!/bin/bash
exec "$APP/Contents/MacOS/continuous" "\$@"
LAUNCHER
chmod +x "$ROOT/build/continuous"

echo "==> Built $APP  (commit $COMMIT)"
echo "    binary  $(du -h "$APP/Contents/MacOS/continuous" | cut -f1)"
echo "    launcher $ROOT/build/continuous"

if [ "$INSTALL" = "1" ]; then
  DEST="/usr/local/bin/continuous"
  echo "==> Installing launcher to $DEST"
  if [ -w "$(dirname "$DEST")" ]; then
    ln -sf "$ROOT/build/continuous" "$DEST"
  else
    sudo ln -sf "$ROOT/build/continuous" "$DEST"
  fi
  echo "    $DEST -> $ROOT/build/continuous"
fi

echo
echo "Next:"
echo "    $ROOT/build/continuous selftest"
echo "    $ROOT/build/continuous doctor"
