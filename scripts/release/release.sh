#!/usr/bin/env bash
# Package a Frost release: bump version -> Release build -> sign (Hardened Runtime) and verify -> DMG
# -> [developer-id: sign, notarize and staple the DMG] -> Sparkle EdDSA -> appcast.xml.
#
#   scripts/release/release.sh <version>             # build artifacts locally, then print the publish commands
#   scripts/release/release.sh <version> --publish   # also commit the version, tag, push and create the GitHub Release
#   SIGNING_MODE=developer-id scripts/release/release.sh --dry-run-notarize   # check the Developer ID setup only
#
# Options:
#   --publish            Publish (requires branch RELEASE_BRANCH, a clean working tree apart from this script's own
#                        version bump, a logged-in gh, a branch containing the remote one, and a passing VM upgrade
#                        test of the DMG a previous run built from this tree; pushes branch and tag atomically).
#   --skip-upgrade-test  Emergencies only, with --publish: publish without a passing upgrade test.
#   --allow-dirty        Allow uncommitted changes (local test builds only; cannot be combined with --publish).
#   --dry-run-notarize   developer-id mode only: run the signing and notarization preflight (identity in the keychain,
#                        TEAM_ID, notary credentials), print the plan and exit without building or submitting.
#
# Artifacts go to build/release/<version>/: Frost.app, Frost-<version>.dmg, appcast.xml, release-notes.md,
# build-info.txt (version, commit and source identity, read by the upgrade test's marker) (developer-id: also
# notarization/ with the notary service's submission result and log).
# Before --publish: make vm-upgrade-test BUILD=build/release/<version>/Frost-<version>.dmg (docs/releasing.md).
# Configuration: scripts/release/config.sh. Full procedure: docs/releasing.md.
set -euo pipefail
# Prefer the system BSD tools (Homebrew coreutils' stat / base64 / date take different arguments).
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
# shellcheck source=scripts/release/config.sh
source "$(dirname "$0")/config.sh"
cd "$FROST_ROOT"

# shellcheck source=scripts/lib/openssl.sh
source "$FROST_ROOT/scripts/lib/openssl.sh"

usage() { sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }
step() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
fail() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
note() { printf '\033[1;33mnote:\033[0m %s\n' "$*" >&2; }

# ---- Cleanup and failure report ----------------------------------------------------------------
# Temporary state is removed on every exit; what a failed run leaves behind is reported, never silent.
MOUNT_POINT=""
TEMP_DIRS=""
BUMPED=""        # "<version> (build <n>)" once project.yml / Info.plist carry an uncommitted version bump
TAGGED=""        # the local tag created by --publish, until it is pushed
on_exit() {
  local status=$?
  if [[ -n $MOUNT_POINT ]]; then hdiutil detach -quiet "$MOUNT_POINT" 2>/dev/null || true; fi
  local dir
  for dir in $TEMP_DIRS; do rm -rf "$dir"; done
  (( status == 0 )) && return
  if [[ -n $BUMPED ]]; then
    note "project.yml and Frost/Resources/Info.plist keep the uncommitted version bump to $BUMPED. Rerunning (with or
      without --publish) reuses it; to undo it: git checkout -- project.yml Frost/Resources/Info.plist"
  fi
  if [[ -n $TAGGED ]]; then
    note "the local tag $TAGGED was created but not pushed; delete it before rerunning: git tag -d $TAGGED"
  fi
}
trap on_exit EXIT
temp_dir() { local dir; dir=$(mktemp -d); TEMP_DIRS="$TEMP_DIRS $dir"; printf '%s\n' "$dir"; }

# git against the --publish remote (GIT_PUSH_URL or GIT_REMOTE); with GIT_USE_GH_CREDENTIALS=1, HTTPS credentials
# come from gh instead of the configured credential helpers (see config.sh).
PUSH_TARGET=${GIT_PUSH_URL:-$GIT_REMOTE}
remote_git() {
  if [[ $GIT_USE_GH_CREDENTIALS == 1 ]]; then
    git -c credential.helper= -c 'credential.helper=!gh auth git-credential' "$@"
  else
    git "$@"
  fi
}

# Whether the uncommitted changes are exactly a version bump left by an earlier run of this script: only project.yml
# and the Info.plist generated from it are modified, and only in their version lines.
VERSION_LINE_RE='^[+-][[:space:]]*(CFBundle(ShortVersionString|Version):[[:space:]]*"[0-9.]+"|<string>[0-9.]+</string>)[[:space:]]*$'
FILE_STATUS_RE='^( M|M |MM) (project\.yml|Frost/Resources/Info\.plist)$'
only_version_bump() {
  local status line diff
  status=$(git status --porcelain) || return 1
  while IFS= read -r line; do
    [[ $line =~ $FILE_STATUS_RE ]] || return 1
  done <<<"$status"
  diff=$(git diff HEAD --unified=0 -- project.yml Frost/Resources/Info.plist) || return 1
  while IFS= read -r line; do
    case $line in
      '+++ '* | '--- '* | '@@'* | 'diff --git'* | 'index '*) ;;
      [+-]*) [[ $line =~ $VERSION_LINE_RE ]] || return 1 ;;
    esac
  done <<<"$diff"
}

VERSION=""
PUBLISH=0
ALLOW_DIRTY=0
DRY_RUN_NOTARIZE=0
SKIP_UPGRADE_TEST=0
for arg in "$@"; do
  case "$arg" in
    --publish) PUBLISH=1 ;;
    --skip-upgrade-test) SKIP_UPGRADE_TEST=1 ;;
    --allow-dirty) ALLOW_DIRTY=1 ;;
    --dry-run-notarize) DRY_RUN_NOTARIZE=1 ;;
    -h|--help) usage ;;
    -*) fail "unknown option: $arg" ;;
    *) [[ -z $VERSION ]] || usage; VERSION="$arg" ;;
  esac
done
if (( DRY_RUN_NOTARIZE )); then
  (( PUBLISH || ALLOW_DIRTY )) && fail "--dry-run-notarize cannot be combined with --publish or --allow-dirty"
  [[ $SIGNING_MODE == developer-id ]] \
    || fail "--dry-run-notarize checks the Developer ID setup: run it with SIGNING_MODE=developer-id (see config.sh)"
  VERSION=${VERSION:-0.0.0}   # only used to name paths in the printed plan
fi
[[ -n $VERSION ]] || usage
[[ $VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "version must look like 1.2.3 (got '$VERSION')"
(( PUBLISH && ALLOW_DIRTY )) && fail "--allow-dirty cannot be combined with --publish"
(( SKIP_UPGRADE_TEST && ! PUBLISH )) && fail "--skip-upgrade-test only applies to --publish"
[[ $GITHUB_REPO =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || fail "FROST_GITHUB_REPO in project.yml is not owner/repo: '$GITHUB_REPO'"

TAG="v$VERSION"
OUT="$RELEASE_ROOT/$VERSION"
APP="$OUT/Frost.app"
DMG_NAME="Frost-$VERSION.dmg"
DMG="$OUT/$DMG_NAME"
DOWNLOAD_URL="https://github.com/$GITHUB_REPO/releases/download/$TAG/$DMG_NAME"
NOTARY_DIR="$OUT/notarization"

# Every executable is signed with the Hardened Runtime (--options runtime) in both modes. The entitlements differ only
# by the library validation exception the self-signed certificate needs (see the comments in both files).
case "$SIGNING_MODE" in
  selfsigned)
    IDENTITY="$SELF_SIGNED_IDENTITY"
    ENTITLEMENTS="$SELF_SIGNED_ENTITLEMENTS"
    # No secure timestamp: Apple's timestamp service only countersigns Apple-issued certificates.
    CODESIGN_FLAGS=(--options runtime --timestamp=none)
    XCODE_SIGN_ARGS=(CODE_SIGN_IDENTITY="$IDENTITY" CODE_SIGN_ENTITLEMENTS="$ENTITLEMENTS")
    ;;
  developer-id)
    IDENTITY="$DEVELOPER_ID_IDENTITY"
    ENTITLEMENTS="$DEVELOPER_ID_ENTITLEMENTS"
    # Notarization requires the Hardened Runtime and a secure timestamp on every executable.
    CODESIGN_FLAGS=(--options runtime --timestamp)
    XCODE_SIGN_ARGS=(CODE_SIGN_IDENTITY="$IDENTITY" DEVELOPMENT_TEAM="$TEAM_ID" CODE_SIGN_ENTITLEMENTS="$ENTITLEMENTS"
                     "OTHER_CODE_SIGN_FLAGS=--timestamp")
    ;;
  *) fail "SIGNING_MODE must be selfsigned or developer-id (got '$SIGNING_MODE')" ;;
esac
[[ -f $ENTITLEMENTS ]] || fail "entitlements file $ENTITLEMENTS not found"

# ---- Preflight ---------------------------------------------------------------------------------
step "Preflight ($SIGNING_MODE signing, repo $GITHUB_REPO)"
for tool in xcodegen xcodebuild codesign hdiutil xmllint; do
  command -v "$tool" >/dev/null || fail "$tool not found"
done
OPENSSL=$(find_openssl) || fail "OpenSSL 3 is required to verify the EdDSA signature (brew install openssl@3)"
echo "  openssl: $OPENSSL"
if [[ $SIGNING_MODE == selfsigned ]]; then
  security find-identity -p codesigning | grep -qF "\"$IDENTITY\"" \
    || fail "signing identity '$IDENTITY' not found in the keychain"
else
  # Developer ID: everything notarization needs is checked before the (long) build.
  [[ $TEAM_ID =~ ^[A-Z0-9]{10}$ ]] \
    || fail "TEAM_ID must be the 10-character Team ID of the Apple Developer account (got '$TEAM_ID'; see config.sh)"
  [[ $IDENTITY != "Developer ID Application:  ("* ]] \
    || fail "DEVELOPER_ID_NAME is not set: the name in the certificate's common name (see config.sh)"
  # -v: only valid identities (certificate chain to Apple trusted, not expired or revoked, private key present).
  identities=$(security find-identity -v -p codesigning) || fail "could not list the code signing identities"
  grep -qF "\"$IDENTITY\"" <<<"$identities" || grep -qF " $IDENTITY " <<<"$identities" \
    || fail "no valid signing identity '$IDENTITY' in the keychain (security find-identity -v -p codesigning lists
      them; create the certificate in Xcode → Settings → Accounts → Manage Certificates → Developer ID Application)"
  if [[ $IDENTITY == "Developer ID Application: "* ]]; then
    # The certificate's organizational unit is its Team ID: catches a TEAM_ID that doesn't belong to the certificate.
    cert_ou=$(security find-certificate -c "$IDENTITY" -p | "$OPENSSL" x509 -noout -subject -nameopt multiline \
      | sed -n 's/^ *organizationalUnitName *= *//p' | head -1)
    [[ $cert_ou == "$TEAM_ID" ]] || fail "the certificate '$IDENTITY' belongs to team '$cert_ou', not TEAM_ID '$TEAM_ID'"
  fi
  for tool in notarytool stapler; do
    xcrun --find "$tool" >/dev/null 2>&1 || fail "xcrun $tool not found (install Xcode or its command line tools)"
  done
  command -v spctl >/dev/null || fail "spctl not found"
  # Cheapest authenticated call: proves the keychain profile exists and its credentials are accepted.
  xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
    || fail "the notary credentials '$NOTARY_PROFILE' are missing or rejected (xcrun notarytool history
      --keychain-profile $NOTARY_PROFILE shows the error). Store them once with:
      xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <apple id> --team-id $TEAM_ID"
  echo "  identity: $IDENTITY (team $TEAM_ID)"
  echo "  notary credentials: keychain profile '$NOTARY_PROFILE' (accepted)"
fi
echo "  entitlements: $ENTITLEMENTS"

if (( DRY_RUN_NOTARIZE )); then
  step "Dry run: the Developer ID setup is complete (nothing was built or submitted)"
  cat <<EOF
A release would:
  1. build the universal Release app with CODE_SIGN_IDENTITY="$IDENTITY", DEVELOPMENT_TEAM=$TEAM_ID;
  2. re-sign inside-out with: codesign --force --sign "$IDENTITY" ${CODESIGN_FLAGS[*]}
     (Sparkle's Installer.xpc, Downloader.xpc [--preserve-metadata=entitlements], Autoupdate, Updater.app,
     Sparkle.framework, then Frost.app with --entitlements $ENTITLEMENTS);
  3. verify: codesign --verify --deep --strict, Team ID, runtime flag, secure timestamp, entitlements;
  4. build the DMG, sign it (codesign --sign "$IDENTITY" --timestamp);
  5. xcrun notarytool submit <dmg> --keychain-profile $NOTARY_PROFILE --wait (log fetched with notarytool log);
  6. xcrun stapler staple <dmg>, stapler validate, spctl -a -t open (DMG) and spctl -a -t exec (app inside);
  7. compute the Sparkle EdDSA signature of the stapled DMG and write appcast.xml.
EOF
  exit 0
fi

if (( PUBLISH )); then
  # Everything that could stop the publication is checked here: before the build and before anything irreversible.
  command -v gh >/dev/null || fail "gh not found"
  gh auth status --hostname github.com >/dev/null 2>&1 \
    || fail "gh is not logged in to github.com (run gh auth login); it creates the GitHub release"
  [[ $(git rev-parse --abbrev-ref HEAD) == "$RELEASE_BRANCH" ]] \
    || fail "--publish must run on branch '$RELEASE_BRANCH' (see RELEASE_BRANCH in config.sh)"
  git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && fail "tag $TAG already exists locally (git tag -d $TAG)"
  echo "  remote: $PUSH_TARGET"
  remote_git fetch --quiet --no-tags "$PUSH_TARGET" "refs/heads/$REMOTE_BRANCH" \
    || fail "could not fetch $REMOTE_BRANCH from $PUSH_TARGET (to use HTTPS with gh's credentials, see GIT_PUSH_URL in config.sh)"
  git merge-base --is-ancestor FETCH_HEAD HEAD \
    || fail "local $RELEASE_BRANCH does not contain $REMOTE_BRANCH of $PUSH_TARGET: pull (or rebase) first"
  remote_tag=$(remote_git ls-remote --tags "$PUSH_TARGET" "refs/tags/$TAG") \
    || fail "could not list the tags of $PUSH_TARGET"
  [[ -z $remote_tag ]] || fail "tag $TAG already exists on $PUSH_TARGET"
fi
if (( ! ALLOW_DIRTY )) && [[ -n $(git status --porcelain) ]]; then
  # A run without --publish leaves its version bump uncommitted (--publish commits it): accept exactly that.
  only_version_bump \
    || fail "the working tree has uncommitted changes (commit them, or pass --allow-dirty for a local test build)"
  echo "  uncommitted: only a version bump in project.yml / Info.plist from an earlier run (reused)"
fi

# ---- Upgrade test gate (--publish) -------------------------------------------------------------------------------
# What a DMG was built from: the commit plus the uncommitted changes (for a release, exactly the version bump).
# Recorded in build-info.txt next to the DMG; the upgrade test copies it into its pass marker.
source_identity() {
  { git rev-parse HEAD; git diff HEAD --binary --no-color --no-ext-diff; } | shasum -a 256 | cut -d' ' -f1
}
marker_value() { sed -n "s/^$1=//p" "$2" | head -1; }
# Prints the pass marker of the DMG an earlier run built from the current tree, or why there is none (status 1).
upgrade_test_marker() {
  local version build marker dmg_sha
  version=$(sed -n 's/^ *CFBundleShortVersionString: *"\(.*\)"/\1/p' project.yml)
  build=$(sed -n 's/^ *CFBundleVersion: *"\(.*\)"/\1/p' project.yml)
  if [[ $version != "$VERSION" ]]; then
    echo "project.yml is at $version, so no release candidate of $VERSION was built from this tree yet"; return 1
  fi
  marker="$UPGRADE_TEST_MARKERS/$VERSION-$build.txt"
  [[ -f $marker ]] || { echo "no upgrade test of Frost $VERSION (build $build) has passed ($marker is missing)"; return 1; }
  [[ -f $DMG ]] || { echo "the release candidate $DMG is missing"; return 1; }
  dmg_sha=$(shasum -a 256 "$DMG" | cut -d' ' -f1)
  [[ $(marker_value dmg_sha256 "$marker") == "$dmg_sha" ]] || {
    echo "the upgrade test passed for another DMG than $DMG (rebuilt since?)"; return 1; }
  [[ $(marker_value source "$marker") == "$(source_identity)" ]] || {
    echo "the tested DMG was built from other sources than the current tree (commit $(marker_value commit "$marker"))"
    return 1; }
  echo "$marker"
}
skip_banner() {
  local bar line
  bar=$(printf '%88s' '' | tr ' ' '!')
  {
    printf '\033[1;41;97m%s\033[0m\n' "$bar"
    for line in "--skip-upgrade-test: PUBLISHING WITHOUT A PASSING UPGRADE TEST" \
                "Nothing checked that this build starts on top of the previous release's data." \
                "Run the upgrade test on it as soon as possible: make vm-upgrade-test BUILD=$TAG"; do
      printf '\033[1;41;97m!!  %-82s!!\033[0m\n' "$line"
    done
    printf '\033[1;41;97m%s\033[0m\n' "$bar"
  } >&2
}
TESTED_MARKER=""
if (( PUBLISH )); then
  if (( SKIP_UPGRADE_TEST )); then
    skip_banner
  elif verdict=$(upgrade_test_marker); then
    TESTED_MARKER=$verdict
    echo "  upgrade test: passed for $(marker_value dmg "$TESTED_MARKER") from $(marker_value previous "$TESTED_MARKER") \
($(marker_value passed_at "$TESTED_MARKER"))"
  else
    fail "refusing to publish: $verdict.
      Build the release candidate and run the upgrade test on it first:
        scripts/release/release.sh $VERSION
        make vm-upgrade-test BUILD=build/release/$VERSION/$DMG_NAME
      (emergencies only: --skip-upgrade-test publishes without it)"
  fi
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
if [[ -n $(git status --porcelain project.yml) ]]; then BUMPED="$VERSION (build $build)"; fi
echo "Frost $VERSION (build $build)"

# ---- Build -------------------------------------------------------------------------------------
step "Build (Release, universal)"
xcodegen generate --quiet
xcodebuild -project Frost.xcodeproj -scheme Frost -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$DERIVED_DATA" -quiet \
  -onlyUsePackageVersionsFromResolvedFile "${XCODE_SIGN_ARGS[@]}" build
rm -rf "$OUT"
mkdir -p "$OUT"
ditto "$DERIVED_DATA/Build/Products/Release/Frost.app" "$APP"

# ---- Code signing ------------------------------------------------------------------------------
# Sign inside-out, one item at a time, in the order of Sparkle's documentation ("Sandboxing", code signing section):
# not --deep, which would replace the entitlements of Sparkle's Downloader.xpc. Sparkle's helpers are ad-hoc signed
# in the xcframework; re-sign them all with the release identity and the Hardened Runtime (CODESIGN_FLAGS).
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
sign --entitlements "$ENTITLEMENTS" "$APP"

step "Verify the app"
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | grep -v -e '--prepared:' -e '--validated:' | sed 's/^/  /'
# Every Mach-O file in the bundle (so code added later can't slip through unsigned or ad-hoc): signed by the release
# identity, with the Hardened Runtime; for Developer ID also with the Team ID and a secure timestamp (notarization
# rejects anything else).
checked=0
while IFS= read -r -d '' file; do
  [[ $(file -b "$file") == *Mach-O* ]] || continue
  name=${file#"$OUT/"}
  info=$(codesign -dvv "$file" 2>&1) || fail "$name is not signed"
  authority=$(sed -n 's/^Authority=//p' <<<"$info" | head -1)
  flags=""
  if [[ $info =~ flags=0x[0-9a-f]+\(([a-z,-]*)\) ]]; then flags=",${BASH_REMATCH[1]},"; fi
  [[ $flags == *,runtime,* ]] || fail "$name is not signed with the Hardened Runtime (flags: $flags)"
  if [[ $SIGNING_MODE == selfsigned ]]; then
    [[ $authority == "$IDENTITY" ]] || fail "$name is signed by '$authority', expected '$IDENTITY'"
  else
    [[ $authority == "Developer ID Application: "* ]] \
      || fail "$name is signed by '$authority', expected a Developer ID Application certificate"
    grep -qx "TeamIdentifier=$TEAM_ID" <<<"$info" || fail "$name does not carry Team ID $TEAM_ID"
    grep -q '^Timestamp=' <<<"$info" || fail "$name has no secure timestamp"
  fi
  checked=$((checked + 1))
done < <(find "$APP" -type f -print0)
(( checked >= 6 )) || fail "only $checked Mach-O files in the bundle (expected Frost and Sparkle with its helpers)"
echo "  $checked executables signed by '$authority' with the Hardened Runtime"
# Entitlements: never get-task-allow (debugging; notarization rejects it), and exactly the Hardened Runtime exceptions
# of this mode's entitlements file (the self-signed mode's library validation exception, none for Developer ID).
app_entitlements=$(codesign -d --entitlements - --xml "$APP" 2>/dev/null) || fail "could not read the app's entitlements"
[[ $app_entitlements != *get-task-allow* ]] || fail "the app has the get-task-allow entitlement"
exceptions=$(grep -o 'com\.apple\.security\.cs\.[a-z-]*' <<<"$app_entitlements" | sort -u | xargs || true)
expected_exceptions=$(plutil -convert xml1 -o - "$ENTITLEMENTS" | grep -o 'com\.apple\.security\.cs\.[a-z-]*' | sort -u | xargs || true)
[[ $exceptions == "$expected_exceptions" ]] \
  || fail "the app's Hardened Runtime exceptions are '$exceptions', expected '$expected_exceptions' ($ENTITLEMENTS)"
echo "  entitlements: $ENTITLEMENTS (Hardened Runtime exceptions: ${exceptions:-none})"
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
  staging=$(temp_dir)
  ditto "$APP" "$staging/Frost.app"
  ln -s /Applications "$staging/Applications"
  hdiutil create -quiet -volname Frost -srcfolder "$staging" -fs HFS+ -format ULFO -ov "$DMG"
fi

if [[ $SIGNING_MODE == developer-id ]]; then
  # Apple's flow for a DMG: sign the app (done) -> put it in the DMG -> sign the DMG -> notarize the DMG -> staple the
  # DMG. The notary service checks the app inside and its ticket covers every piece of code in the DMG, so the app
  # itself is not notarized or stapled separately (its copy in /Applications passes Gatekeeper by the online ticket
  # lookup, and offline too once the stapled DMG has been opened). All of this happens before the Sparkle EdDSA
  # signature: stapling modifies the DMG, and Sparkle must get exactly the stapled file.
  step "Notarize ($NOTARY_PROFILE)"
  codesign --force --sign "$IDENTITY" --timestamp "$DMG"
  codesign --verify --strict "$DMG" || fail "the DMG's signature does not verify"
  echo "  signed $DMG"
  rm -rf "$NOTARY_DIR"
  mkdir -p "$NOTARY_DIR"
  echo "  submitting to the notary service and waiting for the result (usually a few minutes)"
  # The JSON result goes to stdout. Its status decides, not notarytool's exit status; the log is fetched in every
  # case (it also lists warnings for accepted submissions).
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait --timeout 1h --output-format json \
    > "$NOTARY_DIR/submission.json" || true
  submission_id=$(plutil -extract id raw -o - "$NOTARY_DIR/submission.json" 2>/dev/null || true)
  notary_status=$(plutil -extract status raw -o - "$NOTARY_DIR/submission.json" 2>/dev/null || true)
  if [[ -z $submission_id ]]; then
    cat "$NOTARY_DIR/submission.json" >&2
    fail "the DMG could not be submitted for notarization (see the output above)"
  fi
  echo "  submission $submission_id: ${notary_status:-unknown status}"
  notary_log="$NOTARY_DIR/notary-log.json"
  if ! xcrun notarytool log "$submission_id" --keychain-profile "$NOTARY_PROFILE" "$notary_log" >/dev/null 2>&1; then
    notary_log=""
  fi
  if [[ $notary_status != Accepted ]]; then
    if [[ -n $notary_log ]]; then
      printf '\n----- notary log (%s) -----\n' "$notary_log" >&2
      cat "$notary_log" >&2
      printf '%s\n' '-----' >&2
    fi
    case "$notary_status" in
      "In Progress") fail "notarization did not finish within the timeout; the service keeps processing it. Check
      with: xcrun notarytool info $submission_id --keychain-profile $NOTARY_PROFILE, then rerun this script" ;;
      *) fail "notarization was not accepted (status '${notary_status:-unknown}'): the log above lists every issue.
      Fetch it again with: xcrun notarytool log $submission_id --keychain-profile $NOTARY_PROFILE" ;;
    esac
  fi
  if [[ -n $notary_log ]]; then
    echo "  log: $notary_log"
    if grep -q '"severity"' "$notary_log"; then note "the notary service accepted the DMG with warnings: see $notary_log"; fi
  fi
  xcrun stapler staple "$DMG" | sed 's/^/  /'
  xcrun stapler validate "$DMG" | sed 's/^/  /'
  assessment=$(spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG" 2>&1) \
    || { echo "$assessment" >&2; fail "Gatekeeper rejects the stapled DMG"; }
  [[ $assessment == *"source=Notarized Developer ID"* ]] \
    || { echo "$assessment" >&2; fail "Gatekeeper does not see the DMG as notarized"; }
  echo "  Gatekeeper (DMG): ${assessment//$'\n'/; }"
fi

# Mount check: the app inside the DMG matches the one just signed (-nobrowse: not shown in Finder).
mnt=$(temp_dir)
hdiutil attach -quiet -nobrowse -readonly -noautoopen -mountpoint "$mnt" "$DMG"
MOUNT_POINT=$mnt
[[ -L $mnt/Applications ]] || fail "the DMG has no Applications link"
codesign --verify --deep --strict "$mnt/Frost.app" || fail "the app inside the DMG fails codesign verification"
[[ $(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$mnt/Frost.app/Contents/Info.plist") == "$build" ]] \
  || fail "the app inside the DMG has the wrong build number"
if [[ $SIGNING_MODE == developer-id ]]; then
  # Gatekeeper's verdict on the app a user drags out of the DMG. A self-signed app is always rejected here, so this
  # only runs in developer-id mode.
  assessment=$(spctl --assess --type execute --verbose=2 "$mnt/Frost.app" 2>&1) \
    || { echo "$assessment" >&2; fail "Gatekeeper rejects the app inside the DMG"; }
  [[ $assessment == *"source=Notarized Developer ID"* ]] \
    || { echo "$assessment" >&2; fail "Gatekeeper does not see the app inside the DMG as notarized"; }
  echo "  Gatekeeper (app): ${assessment//$'\n'/; }"
fi
hdiutil detach -quiet "$mnt"
MOUNT_POINT=""
echo "  $DMG ($(du -h "$DMG" | cut -f1 | xargs))"

# ---- Sparkle signature -------------------------------------------------------------------------
# Over the final DMG (in developer-id mode the notarized and stapled one): nothing may modify it after this point.
step "Sparkle EdDSA signature"
[[ -x $SPARKLE_BIN/sign_update ]] || fail "Sparkle tools not found in $SPARKLE_BIN (run make build first)"
keydir=$(temp_dir)
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
LENGTH=$(stat -f%z "$DMG")

# Independent check: the signature verifies against the SUPublicEDKey embedded in the app (not against a public
# key derived from the private key).
verify_dir=$(temp_dir)
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

# What this DMG was built from (the upgrade test copies it into its pass marker, which --publish checks).
CDHASH=$(codesign -dvvv "$APP" 2>&1 | sed -n 's/^CDHash=//p' | head -1)
{
  echo "version=$VERSION"
  echo "build=$build"
  echo "commit=$(git rev-parse HEAD)"
  echo "source=$(source_identity)"
  echo "cdhash=$CDHASH"
} > "$OUT/build-info.txt"
if [[ -n $TESTED_MARKER ]]; then
  # --publish rebuilds from the same sources as the tested DMG. Report whether the build reproduced the tested code.
  if [[ $(marker_value cdhash "$TESTED_MARKER") == "$CDHASH" ]]; then
    echo "  same CDHash as the DMG the upgrade test passed ($CDHASH)"
  else
    note "the rebuilt app's CDHash ($CDHASH) differs from the tested DMG's ($(marker_value cdhash "$TESTED_MARKER")):
      same sources, but the build is not bit-for-bit reproducible"
  fi
fi

# ---- Publish -----------------------------------------------------------------------------------
GH_CMD=(gh release create "$TAG" --repo "$GITHUB_REPO" --verify-tag --title "Frost $VERSION"
        --notes-file "$OUT/release-notes.md" "$DMG" "$OUT/appcast.xml")
quote() { printf '%q ' "$@"; }

if (( ! PUBLISH )); then
  step "Done (not published)"
  if [[ -n $(git status --porcelain project.yml Frost/Resources/Info.plist) ]]; then
    echo "project.yml and Frost/Resources/Info.plist carry the version bump to $VERSION (build $build), uncommitted:"
    echo "--publish commits it; to discard it instead: git checkout -- project.yml Frost/Resources/Info.plist"
    echo
  fi
  cat <<EOF
Artifacts: $OUT
To publish, rerun on branch '$RELEASE_BRANCH' with --publish: it reuses the version bump, rebuilds, commits the bump,
tags, pushes branch and tag atomically to $PUSH_TARGET and runs:

  $(quote "${GH_CMD[@]}")

EOF
  exit 0
fi

step "Publish $TAG to $GITHUB_REPO"
if [[ -n $(git status --porcelain project.yml Frost/Resources/Info.plist) ]]; then
  git add project.yml Frost/Resources/Info.plist
  git -c user.name="$COMMIT_AUTHOR_NAME" -c user.email="$COMMIT_AUTHOR_EMAIL" commit -q -m "chore: release $VERSION"
fi
BUMPED=""
[[ -z $(git status --porcelain) ]] || fail "unexpected uncommitted changes after the version bump"
git -c user.name="$COMMIT_AUTHOR_NAME" -c user.email="$COMMIT_AUTHOR_EMAIL" tag -a "$TAG" -m "Frost $VERSION"
TAGGED=$TAG
# --atomic: the branch and the tag land together or not at all (a rejected branch push never leaves a tag behind).
if ! remote_git push --atomic "$PUSH_TARGET" "refs/heads/$RELEASE_BRANCH:refs/heads/$REMOTE_BRANCH" "refs/tags/$TAG"; then
  git tag -d "$TAG" >/dev/null
  TAGGED=""
  fail "the push to $PUSH_TARGET failed; nothing was pushed and the local tag $TAG was deleted. The release commit
      (if any) stays on $RELEASE_BRANCH: fix the cause (e.g. pull), then rerun with --publish"
fi
TAGGED=""
if ! "${GH_CMD[@]}"; then
  fail "branch and tag $TAG were pushed, but creating the GitHub release failed; create it with:
      $(quote "${GH_CMD[@]}")"
fi
echo "Published: https://github.com/$GITHUB_REPO/releases/tag/$TAG"
if (( SKIP_UPGRADE_TEST )); then skip_banner; fi
