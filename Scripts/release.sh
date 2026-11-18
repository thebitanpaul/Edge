#!/bin/bash
#
# Ships a new version of Edge, start to finish. The only command a release needs:
#
#   Scripts/release.sh                 Scripts/release.sh --skip-tests
#
# It asks a few questions up front, then runs on its own:
#   1. checks this Mac: on main, clean, up to date, GitHub login can publish to the repo
#   2. asks for the version, suggesting the next one
#   3. asks you to confirm the "Edge Local Signing" certificate is in the login keychain
#      (offering to import edge-signing.p12), then proves it can sign with it
#   4. writes release notes from the commits since the last release, for you to check or edit
#   5. runs the unit tests
#   6. sets the version in Sources/edge/CLI.swift and commits it
#   7. builds, signs and packs the universal DMG, and checks the signature is the release one
#   8. pushes main and the tag vX.Y.Z
#   9. publishes the GitHub release, marked Latest, and checks the download link serves it
#
# Nothing leaves this Mac before step 8. If anything fails before then, the version commit is
# undone and the repo is as it was. If a later step fails, run this again and give the same
# version: it sees the tag already on this commit and picks up from the build.
#
# It refuses to run unless this Mac has the release certificate's private key (pinned by
# fingerprint, so a same-named certificate does not count) and a GitHub login with push
# access to thebitanpaul/Edge. See Scripts/lib/release-common.sh.

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
. "$ROOT/Scripts/lib/release-common.sh"

CLI="Sources/edge/CLI.swift"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
APP="$ROOT/build/Edge.app"
DIST="$ROOT/dist"

RUN_TESTS=1
for arg in "$@"; do
  case "$arg" in
    --skip-tests) RUN_TESTS=0 ;;
    -h|--help) sed -n '3,/^$/s/^# \{0,1\}//p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg (try --help)" >&2; exit 1 ;;
  esac
done

# ---------------------------------------------------------------------------------------------
# Output and prompts

if [ -t 1 ]; then
  B=$'\033[1m'; RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; DIM=$'\033[2m'; R=$'\033[0m'
else
  B=""; RED=""; GRN=""; YEL=""; DIM=""; R=""
fi
step() { printf '\n%s==> %s%s\n' "$B" "$*" "$R"; }
ok()   { printf '    %s✓%s %s\n' "$GRN" "$R" "$*"; }
warn() { printf '    %s!%s %s\n' "$YEL" "$R" "$*"; }
die()  { printf '\n%s✗ %s%s\n' "$RED" "$*" "$R" >&2; exit 1; }
# read -p writes the prompt to stderr, so this works inside $(...).
ask()  { local a=""; read -r -p "$1" a </dev/tty || true; printf '%s' "$a"; }

{ : </dev/tty; } 2>/dev/null || die "Run this from a terminal: it asks questions."

# ---------------------------------------------------------------------------------------------
# Undo the local version commit if we stop before anything was pushed.

WORK="$(mktemp -d -t edge-release)"
START_HEAD=""
BUMPED=0
PUSHED=0
on_exit() {
  local status=$?
  if [ "$status" -ne 0 ] && [ "$BUMPED" = 1 ] && [ "$PUSHED" = 0 ]; then
    if git reset --quiet --keep "$START_HEAD"; then
      echo "    Undid the version commit. Nothing was pushed; the repo is as it was." >&2
    else
      echo "    Could not undo the version commit. To do it by hand:  git reset --keep $START_HEAD" >&2
    fi
  fi
  rm -rf "$WORK"
}
trap on_exit EXIT
trap 'exit 130' INT TERM

# ---------------------------------------------------------------------------------------------
# Versions

semver_ok() { [[ "$1" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; }
# Succeeds if version $1 is higher than version $2.
ver_gt() {
  local a1 a2 a3 b1 b2 b3
  IFS=. read -r a1 a2 a3 <<<"$1"
  IFS=. read -r b1 b2 b3 <<<"$2"
  [ "$a1" -ne "$b1" ] && { [ "$a1" -gt "$b1" ]; return; }
  [ "$a2" -ne "$b2" ] && { [ "$a2" -gt "$b2" ]; return; }
  [ "$a3" -gt "$b3" ]
}
bump() {
  local ma mi pa
  IFS=. read -r ma mi pa <<<"$2"
  case "$1" in
    patch) echo "$ma.$mi.$((pa + 1))" ;;
    minor) echo "$ma.$((mi + 1)).0" ;;
    major) echo "$((ma + 1)).0.0" ;;
  esac
}
tag_exists() { git rev-parse -q --verify "refs/tags/$1" >/dev/null; }
tag_commit() { git rev-parse "$1^{commit}"; }
# Release tags, newest first. Ends in sed, not head, so nothing upstream dies of SIGPIPE.
release_tags() {
  git tag -l 'v[0-9]*' --sort=-v:refname | while read -r t; do
    if semver_ok "${t#v}"; then echo "$t"; fi
  done
}

# =============================================================================================
step "Checking this Mac and the repo"

for t in git swift codesign security hdiutil python3 curl shasum; do
  command -v "$t" >/dev/null 2>&1 || die "'$t' is missing. Install the Xcode Command Line Tools:  xcode-select --install"
done

BRANCH="$(git symbolic-ref --short -q HEAD || true)"
[ "$BRANCH" = main ] || die "Releases are made from main, and this is '${BRANCH:-a detached HEAD}'.  git switch main"

if ! git diff --quiet || ! git diff --cached --quiet; then
  git status --short --untracked-files=no | sed 's/^/      /'
  die "Commit or stash these changes first: a release is built from a commit, exactly."
fi

# --force: mirror GitHub's tags even if a local one is stale.
git fetch --quiet --force --tags origin main || die "Could not reach GitHub (git fetch failed)."
BEHIND="$(git rev-list --count HEAD..origin/main)"
[ "$BEHIND" = 0 ] || die "main is $BEHIND commit(s) behind GitHub. Run  git pull --ff-only  and start again."
ok "on main, no uncommitted changes, up to date with GitHub"

TOKEN="$(github_token)"
[ -n "$TOKEN" ] || die "No GitHub login on this Mac. Push to GitHub once so the keychain has it, or export GITHUB_TOKEN."
CAN_PUSH="$(curl -sS -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" "$API" \
  | python3 -I -c 'import json,sys; print(json.load(sys.stdin).get("permissions", {}).get("push", False))' 2>/dev/null || true)"
unset TOKEN
[ "$CAN_PUSH" = True ] || die "The GitHub login on this Mac cannot publish to $REPO. Only the repo owner can release Edge."
ok "the GitHub login here can publish to $REPO"

# =============================================================================================
step "Version"

CODE_VERSION="$(sed -n 's/^ *static let shortVersion = "\([^"]*\)".*/\1/p' "$CLI")"
semver_ok "$CODE_VERSION" || die "Could not read  static let shortVersion = \"X.Y.Z\"  from $CLI."
LAST_TAG="$(release_tags | sed -n 1p)"
LAST="${LAST_TAG#v}"
[ -n "$LAST" ] || LAST="0.0.0"
HEAD_SHA="$(git rev-parse HEAD)"

# Recommend finishing an interrupted release, else a version already set in the code but never
# released, else the next patch.
if tag_exists "v$CODE_VERSION" && [ "$(tag_commit "v$CODE_VERSION")" = "$HEAD_SHA" ]; then
  RECOMMENDED="$CODE_VERSION"
  WHY="v$CODE_VERSION is already tagged on this commit — pick it to finish publishing it"
elif ver_gt "$CODE_VERSION" "$LAST"; then
  RECOMMENDED="$CODE_VERSION"
  WHY="already set in $CLI and never released"
else
  RECOMMENDED="$(bump patch "$LAST")"
  WHY="next patch after ${LAST_TAG:-nothing}"
fi
P="$(bump patch "$LAST")"; M="$(bump minor "$LAST")"; J="$(bump major "$LAST")"

if [ -n "$LAST_TAG" ]; then
  SINCE="$(git rev-list --count "$LAST_TAG..HEAD")"
  echo "    Last release ${B}$LAST_TAG${R}  ·  $CLI says ${B}$CODE_VERSION${R}  ·  $SINCE commit(s) since $LAST_TAG"
else
  echo "    No release yet  ·  $CLI says ${B}$CODE_VERSION${R}"
fi
cat <<EOF

      1) $P   patch — bug fixes only
      2) $M   minor — new features, still works with the previous version
      3) $J   major — breaking change: both Macs must update together

    Recommended: ${B}$RECOMMENDED${R}  ${DIM}($WHY)${R}
EOF

RESUME=0
while :; do
  ANSWER="$(ask "    Version — Enter for $RECOMMENDED, 1/2/3, or type one: ")"
  case "$ANSWER" in
    "") VERSION="$RECOMMENDED" ;;
    1) VERSION="$P" ;;
    2) VERSION="$M" ;;
    3) VERSION="$J" ;;
    *) VERSION="${ANSWER#v}"; VERSION="${VERSION// /}" ;;
  esac
  semver_ok "$VERSION" || { warn "'$ANSWER' is not a version like 1.2.3."; continue; }
  TAG="v$VERSION"
  if tag_exists "$TAG"; then
    if [ "$(tag_commit "$TAG")" = "$HEAD_SHA" ] && [ "$VERSION" = "$CODE_VERSION" ]; then
      RESUME=1
      break
    fi
    warn "$TAG is already released, from another commit. Versions are never reused."
    continue
  fi
  ver_gt "$VERSION" "$LAST" || { warn "It must be higher than the last release, $LAST."; continue; }
  break
done

if [ "$RESUME" = 1 ]; then
  ok "$VERSION — finishing the release of $TAG, which is already tagged on this commit"
else
  [ -z "$LAST_TAG" ] || [ "$SINCE" != 0 ] || die "Nothing has changed since $LAST_TAG — there is nothing to release."
  ok "$VERSION"
fi

# =============================================================================================
step "Signing certificate"

cat <<EOF
    Every release must be signed with the ${B}$SIGNING_NAME${R} certificate — the same one as
    every earlier release — or all users have to grant Accessibility and Input Monitoring again.
    It has to be in ${B}Keychain Access ▸ login ▸ My Certificates${R} on this Mac.

    Not there? Its backup, ${B}edge-signing.p12${R}, is in the ${B}Edge${R} folder on your Google Drive.
    Download it and import it into the ${B}login${R} keychain: double-click it, or drop it on this
    window when asked below.

EOF

explain_missing_identity() {
  if [ -n "$(pinned_cert_sha1)" ]; then
    warn "The certificate is here, but macOS will not sign with it yet. Either its private key"
    warn "is missing (import the .p12, not a .cer), or it is not trusted: Keychain Access ▸"
    warn "My Certificates ▸ double-click \"$SIGNING_NAME\" ▸ Trust ▸ Code Signing: Always Trust."
  elif security find-certificate -c "$SIGNING_NAME" >/dev/null 2>&1; then
    warn "This Mac has a certificate called \"$SIGNING_NAME\", but it is NOT the release one"
    warn "(different fingerprint — probably made by Scripts/create-signing-identity.sh)."
    warn "Only the certificate backed up as edge-signing.p12 can sign a release."
  else
    warn "There is no \"$SIGNING_NAME\" certificate in any keychain on this Mac."
  fi
}

import_p12() {
  local p12="$1" pw out pem
  [ -f "$p12" ] || { warn "No file at: $p12"; return 0; }
  read -r -s -p "    Password for $(basename "$p12"): " pw </dev/tty || true
  echo
  if out="$(security import "$p12" -k "$KEYCHAIN" -f pkcs12 -P "$pw" \
              -T /usr/bin/codesign -T /usr/bin/security 2>&1)"; then
    ok "imported into the login keychain"
  elif printf '%s' "$out" | grep -F "already exists" >/dev/null; then
    ok "already in the login keychain"
  else
    warn "Import failed: ${out:-wrong password?}"
    return 0
  fi
  if [ -z "$(pinned_cert_sha1)" ]; then
    warn "That file does not hold the release certificate (its fingerprint is different)."
    return 0
  fi
  if [ -z "$(pinned_identity_sha1)" ]; then
    echo "    Trusting it for code signing — macOS may ask for your password…"
    pem="$WORK/cert.pem"
    security find-certificate -a -c "$SIGNING_NAME" -Z -p | awk -v want="$SIGNING_SHA256" '
      /^SHA-256 hash:/      { take = ($3 == want); next }
      take && /BEGIN CERT/  { p = 1 }
      p                     { print }
      p && /END CERT/       { exit }' > "$pem"
    security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$pem" \
      || warn "Could not set the trust automatically."
  fi
}

SHA1=""
while [ -z "$SHA1" ]; do
  case "$(ask "    Is the \"$SIGNING_NAME\" certificate in your login keychain? [y/N] ")" in
    y|Y|yes|Yes|YES)
      SHA1="$(pinned_identity_sha1)"
      [ -n "$SHA1" ] || explain_missing_identity
      ;;
    *)
      echo "    Drop edge-signing.p12 (from Google Drive ▸ Edge) on this window and press Enter to"
      echo "    import it — or import it in Keychain Access yourself and just press Enter."
      FILE="$(ask "    .p12 file, Enter when imported, or q to stop: ")"
      case "$FILE" in
        q|Q) die "Stopped. Nothing was changed." ;;
        "") ;;
        *)
          # Terminal pastes a dropped path with backslash-escaped spaces, or in quotes.
          FILE="${FILE//\\ / }"; FILE="${FILE%"${FILE##*[![:space:]]}"}"
          FILE="${FILE#\'}"; FILE="${FILE%\'}"; FILE="${FILE#\"}"; FILE="${FILE%\"}"
          FILE="${FILE/#\~/$HOME}"
          import_p12 "$FILE"
          SHA1="$(pinned_identity_sha1)"
          [ -n "$SHA1" ] || explain_missing_identity
          ;;
      esac
      ;;
  esac
done
ok "found the release certificate ($SHA1)"

echo "    Test-signing with it. If macOS asks whether codesign may use the key, enter your"
echo "    login password and click ${B}Always Allow${R} (plain Allow would ask again mid-build)."
PROBE="$WORK/probe"
cp /usr/bin/true "$PROBE"
codesign --force --sign "$SHA1" "$PROBE" >"$WORK/probe.log" 2>&1 \
  || { sed 's/^/    /' "$WORK/probe.log"; die "codesign could not use the key. Nothing was changed."; }
signed_by_pinned_cert "$PROBE" || die "The test signature did not come out as the release certificate."
ok "this Mac can sign Edge releases"

# =============================================================================================
step "Release notes"

mkdir -p "$DIST"
NOTES="$DIST/release-notes-$VERSION.md"

# The release before this one, to list what changed since.
PREV_TAG=""
for t in $(release_tags); do
  if [ "$t" != "$TAG" ] && ver_gt "$VERSION" "${t#v}"; then PREV_TAG="$t"; break; fi
done

write_notes() {
  local range="${PREV_TAG:+$PREV_TAG..}HEAD" line hash subj new="" fixes="" skipped=0
  # Only commits that change the app itself. Scripts, docs and tests are not news to users.
  local app_paths='^(Sources/|Resources/|Package\.swift$|Package\.resolved$)'
  local fix_words='(^|[^[:alpha:]])(fix|fixes|fixed|fixing|bug|bugs|crash|crashes|crashed|broken|wrong|regression|stop|stops|prevent|prevents|repair|restore|correct)([^[:alpha:]]|$)'
  while IFS= read -r line; do
    hash="${line%% *}"; subj="${line#* }"
    # Version bumps and release housekeeping ("Edge 1.0.1", "Release 1.0.0: …") aren't news.
    [[ "$subj" =~ ^(Edge|Release)\ v?[0-9]+\.[0-9]+\.[0-9]+([:\ ]|$) ]] && continue
    if ! git diff-tree --no-commit-id --name-only -r "$hash" | grep -E "$app_paths" >/dev/null; then
      skipped=$((skipped + 1)); continue
    fi
    if printf '%s' "$subj" | grep -Ei "$fix_words" >/dev/null; then
      fixes="$fixes- $subj"$'\n'
    else
      new="$new- $subj"$'\n'
    fi
  done < <(git log --no-merges --reverse --format='%h %s' "$range")

  echo "## What's changed in Edge $VERSION"
  echo
  if [ -z "$new$fixes" ]; then
    echo "- Small internal improvements."
    echo
  fi
  [ -z "$new" ]   || printf '### New and improved\n%s\n' "$new"
  [ -z "$fixes" ] || printf '### Fixes\n%s\n' "$fixes"
  [ -z "$PREV_TAG" ] || echo "**Full changelog:** https://github.com/$REPO/compare/$PREV_TAG...$TAG"
  echo "$skipped" > "$WORK/skipped"
}

new_notes() {
  write_notes > "$NOTES"
  SKIPPED="$(cat "$WORK/skipped")"
  ok "written from the commits since ${PREV_TAG:-the beginning}"
  [ "$SKIPPED" = 0 ] || ok "left out $SKIPPED commit(s) that only touch scripts, docs or tests"
}
# Keep notes from an earlier, stopped run of this version: they may have been edited.
if [ -f "$NOTES" ]; then
  ok "using the notes from last time (${NOTES#$ROOT/}) — r below writes them afresh"
else
  new_notes
fi

while :; do
  echo "    ${DIM}┌──────────────────────────────────────────────────────────────────────${R}"
  sed "s/^/    ${DIM}│${R} /" "$NOTES"
  echo "    ${DIM}└──────────────────────────────────────────────────────────────────────${R}"
  echo "    Download link, install steps and checksum are added below these automatically."
  case "$(ask "    Enter to use these notes, e to edit, r to rewrite from the commits, q to stop: ")" in
    "") break ;;
    r|R) new_notes ;;
    e|E)
      ED="${VISUAL:-${EDITOR:-nano}}"
      # Unquoted on purpose: EDITOR may carry arguments, like "code --wait".
      $ED "$NOTES" </dev/tty >/dev/tty || warn "The editor exited with an error."
      ;;
    q|Q) die "Stopped. Nothing was changed. (Notes kept in ${NOTES#$ROOT/}.)" ;;
  esac
done

# =============================================================================================
step "Ready to release Edge $VERSION"

if [ "$RESUME" = 1 ]; then
  echo "    Commit     $(git log -1 --format='%h %s') — already tagged $TAG"
else
  if [ "$VERSION" != "$CODE_VERSION" ]; then
    echo "    Commit     \"Edge $VERSION\" (sets $CLI) on top of $(git rev-parse --short HEAD)"
  fi
  echo "    Tag        $TAG"
fi
echo "    Signed by  $SIGNING_NAME ($SHA1)"
echo "    Publishes  https://github.com/$REPO/releases — marked Latest, so the website serves it"
echo "    Tests      $([ "$RUN_TESTS" = 1 ] && echo "run first" || echo "skipped (--skip-tests)")"
echo
case "$(ask "    Go ahead? Nothing is pushed until the signed build checks out. [Y/n] ")" in
  ""|y|Y|yes|Yes|YES) ;;
  *) die "Stopped. Nothing was changed." ;;
esac

# From here on it runs by itself.

if [ "$RUN_TESTS" = 1 ]; then
  step "Running the unit tests"
  TEST_LOG="$DIST/test-$VERSION.log"
  if ! Scripts/test.sh >"$TEST_LOG" 2>&1; then
    tail -30 "$TEST_LOG" | sed 's/^/    /'
    die "Tests failed — nothing was released. Full log: ${TEST_LOG#$ROOT/}"
  fi
  ok "tests pass"
fi

if [ "$VERSION" != "$CODE_VERSION" ]; then
  step "Setting the version to $VERSION"
  START_HEAD="$HEAD_SHA"
  sed -i '' "s/^\( *static let shortVersion = \"\)[^\"]*\"/\1$VERSION\"/" "$CLI"
  grep -F "static let shortVersion = \"$VERSION\"" "$CLI" >/dev/null || die "Could not set the version in $CLI."
  BUMPED=1
  git commit --quiet -m "Edge $VERSION" -- "$CLI"
  ok "$CLI → $VERSION, committed as $(git rev-parse --short HEAD) (not pushed yet)"
fi

step "Building, signing and packing the universal DMG — this takes a few minutes"
BUILD_LOG="$DIST/build-$VERSION.log"
# By SHA-1, so build.sh signs with exactly the certificate checked above.
if ! EDGE_SIGNING_IDENTITY="$SHA1" Scripts/package-dmg.sh 2>&1 | tee "$BUILD_LOG" | sed 's/^/    /'; then
  die "The build failed — nothing was pushed. Log: ${BUILD_LOG#$ROOT/}"
fi

step "Checking the build"
signed_by_pinned_cert "$APP" \
  || die "build/Edge.app is not signed with the release certificate (look for 'falling back to ad-hoc' above). Nothing was pushed."
PLIST="$APP/Contents/Info.plist"
BUILT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$PLIST")"
BUILT_COMMIT="$(/usr/libexec/PlistBuddy -c 'Print EdgeCommit' "$PLIST")"
[ "$BUILT_VERSION" = "$VERSION" ] || die "The app says version $BUILT_VERSION, not $VERSION. Nothing was pushed."
[ "$BUILT_COMMIT" = "$(git rev-parse --short HEAD)" ] \
  || die "The app was built from '$BUILT_COMMIT', not the release commit $(git rev-parse --short HEAD). Nothing was pushed."
# And the copy people will actually download.
MNT="$WORK/mnt"
mkdir -p "$MNT"
hdiutil attach -quiet -nobrowse -noautoopen -readonly -mountpoint "$MNT" "$DIST/Edge.dmg"
DMG_OK=0
signed_by_pinned_cert "$MNT/Edge.app" && DMG_OK=1
hdiutil detach -quiet "$MNT" || true
[ "$DMG_OK" = 1 ] || die "The Edge.app inside dist/Edge.dmg is not signed with the release certificate. Nothing was pushed."
ok "Edge $VERSION, built from $BUILT_COMMIT, signed with the release certificate — app and DMG"

step "Pushing to GitHub"
if [ "$(git rev-list --count origin/main..HEAD)" != 0 ]; then
  git push --quiet origin HEAD:main || die "git push was refused — nothing was pushed."
fi
PUSHED=1
ok "main"
tag_exists "$TAG" || git tag -a "$TAG" -m "Edge $VERSION"
if [ -z "$(git ls-remote origin "refs/tags/$TAG")" ]; then
  git push --quiet origin "$TAG" \
    || die "Could not push $TAG. Run Scripts/release.sh again and pick $VERSION to finish."
fi
ok "$TAG"

step "Publishing the GitHub release"
if ! Scripts/publish-release.sh --notes "$NOTES" 2>&1 | sed 's/^/    /'; then
  die "Publishing failed. Run Scripts/release.sh again and pick $VERSION — it picks up from the build."
fi

step "Checking the website's download link"
LIVE=0
for _ in 1 2 3 4 5 6; do
  LOC="$(curl -sI "https://github.com/$REPO/releases/latest/download/Edge.dmg" \
         | tr -d '\r' | awk 'tolower($1) == "location:" { print $2; exit }')"
  case "$LOC" in *"/download/$TAG/Edge.dmg") LIVE=1; break ;; esac
  sleep 5
done
if [ "$LIVE" = 1 ]; then
  ok "…/releases/latest/download/Edge.dmg now serves $TAG"
else
  warn "The download link still points at ${LOC:-nothing}. GitHub can lag a minute; check again with:"
  warn "  curl -sI https://github.com/$REPO/releases/latest/download/Edge.dmg | grep -i location"
fi

printf '\n%s✓ Edge %s is released.%s\n' "$GRN$B" "$VERSION" "$R"
echo "    Release   https://github.com/$REPO/releases/tag/$TAG"
echo "    Download  https://github.com/$REPO/releases/latest/download/Edge.dmg"
echo "    On your other Mac:  git pull"
