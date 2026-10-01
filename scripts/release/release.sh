#!/usr/bin/env bash
# Package a Frost release: bump version -> Release build -> sign and verify -> DMG -> Sparkle EdDSA -> appcast.xml.
#
#   scripts/release/release.sh <version>             # build artifacts locally, then print the publish commands
#   scripts/release/release.sh <version> --publish   # also commit the version, tag, push and create the GitHub Release
#
# Options:
#   --publish       Publish (requires branch RELEASE_BRANCH, a clean working tree and a logged-in gh).
#   --allow-dirty   Allow uncommitted changes (local test builds only; cannot be combined with --publish).
#
# Artifacts go to build/release/<version>/: Frost.app, Frost-<version>.dmg, appcast.xml, release-notes.md.
# Configuration: scripts/release/config.sh. Full procedure: docs/releasing.md.
set -euo pipefail
# Prefer the system BSD tools (Homebrew coreutils' stat / base64 / date take different arguments).
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
# shellcheck source=scripts/release/config.sh
source "$(dirname "$0")/config.sh"
cd "$FROST_ROOT"

usage() { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }
step() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
fail() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

VERSION=""
PUBLISH=0
ALLOW_DIRTY=0
for arg in "$@"; do
  case "$arg" in
    --publish) PUBLISH=1 ;;
    --allow-dirty) ALLOW_DIRTY=1 ;;
    -h|--help) usage ;;
    -*) fail "unknown option: $arg" ;;
    *) [[ -z $VERSION ]] || usage; VERSION="$arg" ;;
  esac
done
[[ -n $VERSION ]] || usage
[[ $VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "version must look like 1.2.3 (got '$VERSION')"
(( PUBLISH && ALLOW_DIRTY )) && fail "--allow-dirty cannot be combined with --publish"
[[ $GITHUB_REPO =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || fail "FROST_GITHUB_REPO in project.yml is not owner/repo: '$GITHUB_REPO'"

TAG="v$VERSION"
OUT="$RELEASE_ROOT/$VERSION"
APP="$OUT/Frost.app"
DMG_NAME="Frost-$VERSION.dmg"
DMG="$OUT/$DMG_NAME"
DOWNLOAD_URL="https://github.com/$GITHUB_REPO/releases/download/$TAG/$DMG_NAME"

case "$SIGNING_MODE" in
  selfsigned)
    IDENTITY="$SELF_SIGNED_IDENTITY"
    CODESIGN_FLAGS=(--timestamp=none)
    XCODE_SIGN_ARGS=(CODE_SIGN_IDENTITY="$IDENTITY")
    ;;
  developer-id)
    # Optional path (untested): Developer ID + hardened runtime + notarization.
    IDENTITY="$DEVELOPER_ID_IDENTITY"
    CODESIGN_FLAGS=(--options runtime --timestamp)
    XCODE_SIGN_ARGS=(CODE_SIGN_IDENTITY="$IDENTITY" DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM_ID"
                     ENABLE_HARDENED_RUNTIME=YES "OTHER_CODE_SIGN_FLAGS=--timestamp")
    ;;
  *) fail "SIGNING_MODE must be selfsigned or developer-id (got '$SIGNING_MODE')" ;;
esac

# ---- Preflight ---------------------------------------------------------------------------------
step "Preflight ($SIGNING_MODE signing, repo $GITHUB_REPO)"
for tool in xcodegen xcodebuild codesign hdiutil xmllint; do
  command -v "$tool" >/dev/null || fail "$tool not found"
done
OPENSSL=/opt/homebrew/bin/openssl
[[ -x $OPENSSL ]] || OPENSSL=$(command -v openssl)
"$OPENSSL" version | grep -q '^OpenSSL 3' || fail "OpenSSL 3 is required to verify the EdDSA signature (brew install openssl)"
security find-identity -p codesigning | grep -qF "\"$IDENTITY\"" || fail "signing identity '$IDENTITY' not found in the keychain"

if (( PUBLISH )); then
  command -v gh >/dev/null || fail "gh not found"
  [[ $(git rev-parse --abbrev-ref HEAD) == "$RELEASE_BRANCH" ]] \
    || fail "--publish must run on branch '$RELEASE_BRANCH' (see RELEASE_BRANCH in config.sh)"
  git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && fail "tag $TAG already exists"
fi
if (( ! ALLOW_DIRTY )) && [[ -n $(git status --porcelain) ]]; then
  fail "the working tree has uncommitted changes (commit them, or pass --allow-dirty for a local test build)"
fi

# The release notes are the "## [<version>]" section of CHANGELOG.md.
NOTES=$(awk -v v="$VERSION" '
  /^## / { if (found) exit; if (index($0, "[" v "]")) { found = 1; next } }
  found { print }
' CHANGELOG.md | sed -e '/./,$!d' | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}')
[[ -n $NOTES ]] || fail "CHANGELOG.md has no '## [$VERSION]' section"
[[ $NOTES != *']]>'* ]] || fail "release notes must not contain ']]>'"

# ---- Version -----------------------------------------------------------------------------------
step "Version"
current_version=$(sed -n 's/^ *CFBundleShortVersionString: *"\(.*\)"/\1/p' project.yml)
current_build=$(sed -n 's/^ *CFBundleVersion: *"\(.*\)"/\1/p' project.yml)
[[ $current_build =~ ^[0-9]+$ ]] || fail "CFBundleVersion in project.yml must be an integer"
if [[ $current_version == "$VERSION" ]]; then
  build=$current_build                       # repackaging the same version: keep the build number
else
  newest=$(printf '%s\n%s\n' "$current_version" "$VERSION" | sort -V | tail -1)
  [[ $newest == "$VERSION" ]] || fail "$VERSION is lower than the current version $current_version"
  build=$((current_build + 1))               # Sparkle compares CFBundleVersion, so it must increase
fi
sed -i '' -e "s/^\( *CFBundleShortVersionString: *\)\".*\"/\1\"$VERSION\"/" \
          -e "s/^\( *CFBundleVersion: *\)\".*\"/\1\"$build\"/" project.yml
echo "Frost $VERSION (build $build)"

# ---- Build -------------------------------------------------------------------------------------
step "Build (Release, universal)"
xcodegen generate --quiet
xcodebuild -project Frost.xcodeproj -scheme Frost -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$DERIVED_DATA" -quiet \
  "${XCODE_SIGN_ARGS[@]}" build
rm -rf "$OUT"
mkdir -p "$OUT"
ditto "$DERIVED_DATA/Build/Products/Release/Frost.app" "$APP"

# ---- Code signing ------------------------------------------------------------------------------
# Sign inside-out, one item at a time (not --deep: it drops the entitlements of Sparkle's Downloader.xpc).
# Sparkle's helpers are ad-hoc signed in the xcframework; re-sign them all with the release identity.
step "Code sign ($IDENTITY)"
sign() {
  local output
  output=$(codesign --force --sign "$IDENTITY" "${CODESIGN_FLAGS[@]}" "$@" 2>&1) || { echo "$output" >&2; fail "codesign failed"; }
  echo "  signed ${*: -1}"
}
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
SPARKLE_B="$SPARKLE/Versions/B"
[[ -d $SPARKLE_B ]] || fail "Sparkle.framework not found in the app bundle"
[[ -d $SPARKLE_B/XPCServices/Installer.xpc ]] && sign "$SPARKLE_B/XPCServices/Installer.xpc"
[[ -d $SPARKLE_B/XPCServices/Downloader.xpc ]] && sign --preserve-metadata=entitlements "$SPARKLE_B/XPCServices/Downloader.xpc"
sign "$SPARKLE_B/Autoupdate"
sign "$SPARKLE_B/Updater.app"
sign "$SPARKLE"
sign --entitlements Frost/Resources/Frost.entitlements "$APP"

step "Verify the app"
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | grep -v -e '--prepared:' -e '--validated:' | sed 's/^/  /'
for code in "$APP" "$SPARKLE" "$SPARKLE_B/Autoupdate" "$SPARKLE_B/Updater.app"; do
  authority=$(codesign -dvv "$code" 2>&1 | sed -n 's/^Authority=//p' | head -1)
  [[ $authority == "$IDENTITY" ]] || fail "$code is signed by '$authority', expected '$IDENTITY'"
done
echo "  signed by: $IDENTITY"
echo "  designated requirement: $(codesign -d -r- "$APP" 2>&1 | sed -n 's/^designated => //p')"
plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$APP/Contents/Info.plist"; }
[[ $(plist CFBundleShortVersionString) == "$VERSION" ]] || fail "CFBundleShortVersionString mismatch"
[[ $(plist CFBundleVersion) == "$build" ]] || fail "CFBundleVersion mismatch"
[[ $(plist SUFeedURL) == "$FEED_URL" ]] || fail "SUFeedURL is '$(plist SUFeedURL)', expected '$FEED_URL'"
PUBLIC_KEY=$(plist SUPublicEDKey)
echo "  SUFeedURL: $FEED_URL"
echo "  SUPublicEDKey: $PUBLIC_KEY"
echo "  architectures: $(lipo -archs "$APP/Contents/MacOS/Frost")"

# ---- DMG ----------------------------------------------------------------------------------------
step "Disk image"
if command -v uvx >/dev/null; then
  "${DMGBUILD[@]}" -s scripts/release/dmg/dmg-settings.py -D app="$APP" \
    -D background="$FROST_ROOT/scripts/release/dmg/background.png" Frost "$DMG"
else
  # Without uv, fall back to a plain DMG without a background.
  echo "  uvx not found: building a plain DMG without background (brew install uv for the styled one)"
  staging=$(mktemp -d)
  ditto "$APP" "$staging/Frost.app"
  ln -s /Applications "$staging/Applications"
  hdiutil create -quiet -volname Frost -srcfolder "$staging" -fs HFS+ -format ULFO -ov "$DMG"
  rm -rf "$staging"
fi

if [[ $SIGNING_MODE == developer-id ]]; then
  # Optional path (untested): sign the DMG, notarize it and staple the ticket. Must happen before the EdDSA
  # signature (stapling modifies the file).
  step "Notarize (untested optional path)"
  codesign --force --sign "$IDENTITY" --timestamp "$DMG"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
fi

# Mount check: the app inside the DMG matches the one just signed (-nobrowse: not shown in Finder).
mnt=$(mktemp -d)
hdiutil attach -quiet -nobrowse -readonly -noautoopen -mountpoint "$mnt" "$DMG"
trap 'hdiutil detach -quiet "$mnt" 2>/dev/null || true' EXIT
[[ -L $mnt/Applications ]] || fail "the DMG has no Applications link"
codesign --verify --deep --strict "$mnt/Frost.app" || fail "the app inside the DMG fails codesign verification"
[[ $(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$mnt/Frost.app/Contents/Info.plist") == "$build" ]] \
  || fail "the app inside the DMG has the wrong build number"
hdiutil detach -quiet "$mnt"
trap - EXIT
echo "  $DMG ($(du -h "$DMG" | cut -f1 | xargs))"

# ---- Sparkle signature -------------------------------------------------------------------------
step "Sparkle EdDSA signature"
[[ -x $SPARKLE_BIN/sign_update ]] || fail "Sparkle tools not found in $SPARKLE_BIN (run make build first)"
keydir=$(mktemp -d)
trap 'rm -rf "$keydir"' EXIT
if [[ -n $SPARKLE_KEY_FILE ]]; then
  keyfile=$SPARKLE_KEY_FILE
else
  # Export the private key with generate_keys, which created the keychain item (so no keychain access prompt
  # appears); it only exists in a temporary directory until the script ends.
  [[ $("$SPARKLE_BIN/generate_keys" --account "$SPARKLE_ACCOUNT" -p) == "$PUBLIC_KEY" ]] \
    || fail "the EdDSA key in the keychain (account $SPARKLE_ACCOUNT) does not match SUPublicEDKey in project.yml"
  keyfile="$keydir/ed25519"
  (umask 077 && "$SPARKLE_BIN/generate_keys" --account "$SPARKLE_ACCOUNT" -x "$keyfile" >/dev/null)
fi
ED_SIGNATURE=$("$SPARKLE_BIN/sign_update" --ed-key-file "$keyfile" -p "$DMG")
rm -rf "$keydir"
trap - EXIT
LENGTH=$(stat -f%z "$DMG")

# Independent check: the signature verifies against the SUPublicEDKey embedded in the app (not against a public
# key derived from the private key).
verify_dir=$(mktemp -d)
{ printf '\x30\x2a\x30\x05\x06\x03\x2b\x65\x70\x03\x21\x00'; base64 -D <<<"$PUBLIC_KEY"; } > "$verify_dir/pub.der"
base64 -D <<<"$ED_SIGNATURE" > "$verify_dir/sig"
"$OPENSSL" pkeyutl -verify -pubin -keyform DER -inkey "$verify_dir/pub.der" -rawin \
  -in "$DMG" -sigfile "$verify_dir/sig" >/dev/null || fail "the EdDSA signature does not verify against SUPublicEDKey"
rm -rf "$verify_dir"
echo "  edSignature verified against SUPublicEDKey (length $LENGTH)"

# ---- appcast and release notes -----------------------------------------------------------------
step "appcast.xml"
printf '%s\n' "$NOTES" > "$OUT/release-notes.md"
min_os=$(plist LSMinimumSystemVersion)
pub_date=$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')
cat > "$OUT/appcast.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>Frost</title>
    <link>https://github.com/$GITHUB_REPO</link>
    <description>Frost updates</description>
    <item>
      <title>Frost $VERSION</title>
      <pubDate>$pub_date</pubDate>
      <link>https://github.com/$GITHUB_REPO/releases/tag/$TAG</link>
      <sparkle:version>$build</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$min_os</sparkle:minimumSystemVersion>
      <description sparkle:format="markdown"><![CDATA[
$NOTES
]]></description>
      <enclosure url="$DOWNLOAD_URL" length="$LENGTH" type="application/octet-stream" sparkle:edSignature="$ED_SIGNATURE"/>
    </item>
  </channel>
</rss>
EOF
xmllint --noout "$OUT/appcast.xml"
echo "  $OUT/appcast.xml (valid XML)"

# ---- Publish -----------------------------------------------------------------------------------
GH_CMD=(gh release create "$TAG" --repo "$GITHUB_REPO" --verify-tag --title "Frost $VERSION"
        --notes-file "$OUT/release-notes.md" "$DMG" "$OUT/appcast.xml")
quote() { printf '%q ' "$@"; }

if (( ! PUBLISH )); then
  step "Done (not published)"
  cat <<EOF
Artifacts: $OUT
To publish this build (or rerun with --publish on branch '$RELEASE_BRANCH'):

  git add project.yml Frost/Resources/Info.plist && git commit -m "chore: release $VERSION"   # if the version changed
  git tag -a $TAG -m "Frost $VERSION"
  git push $GIT_REMOTE $RELEASE_BRANCH:$REMOTE_BRANCH $TAG
  $(quote "${GH_CMD[@]}")

EOF
  exit 0
fi

step "Publish $TAG to $GITHUB_REPO"
if [[ -n $(git status --porcelain project.yml Frost/Resources/Info.plist) ]]; then
  git add project.yml Frost/Resources/Info.plist
  git -c user.name="$COMMIT_AUTHOR_NAME" -c user.email="$COMMIT_AUTHOR_EMAIL" commit -q -m "chore: release $VERSION"
fi
[[ -z $(git status --porcelain) ]] || fail "unexpected uncommitted changes after the version bump"
git -c user.name="$COMMIT_AUTHOR_NAME" -c user.email="$COMMIT_AUTHOR_EMAIL" tag -a "$TAG" -m "Frost $VERSION"
git push "$GIT_REMOTE" "$RELEASE_BRANCH:$REMOTE_BRANCH" "$TAG"
"${GH_CMD[@]}"
echo "Published: https://github.com/$GITHUB_REPO/releases/tag/$TAG"
