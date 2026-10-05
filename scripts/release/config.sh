# shellcheck shell=bash
# shellcheck disable=SC2034  # variables are used by the scripts that source this file
# Release configuration, sourced by scripts/release/*.sh. Every value can be overridden temporarily with an
# environment variable of the same name. See docs/releasing.md.

FROST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# ---- GitHub repository ------------------------------------------------------------------------
# The single source of owner/repo is FROST_GITHUB_REPO in project.yml (SUFeedURL in Info.plist is built from it
# too). To change the repository, change only that line in project.yml.
GITHUB_REPO="${GITHUB_REPO:-$(sed -n 's/^[[:space:]]*FROST_GITHUB_REPO:[[:space:]]*//p' "$FROST_ROOT/project.yml" | head -1)}"
FEED_URL="https://github.com/$GITHUB_REPO/releases/latest/download/appcast.xml"

# Where --publish pushes: local branch RELEASE_BRANCH is pushed to REMOTE_BRANCH on GIT_REMOTE (together with the
# tag, atomically). Before building, --publish fetches REMOTE_BRANCH from there and checks that RELEASE_BRANCH contains
# it and that the tag doesn't exist there yet.
RELEASE_BRANCH="${RELEASE_BRANCH:-main}"
GIT_REMOTE="${GIT_REMOTE:-origin}"
REMOTE_BRANCH="${REMOTE_BRANCH:-main}"
# Optional: a URL to fetch from / push to instead of GIT_REMOTE (e.g. when the remote's SSH URL can't be used because
# the ssh agent is unavailable). With GIT_USE_GH_CREDENTIALS=1, HTTPS credentials come from gh (`gh auth
# git-credential`) instead of the configured credential helpers:
#   GIT_PUSH_URL=https://<user>@github.com/<owner>/<repo>.git GIT_USE_GH_CREDENTIALS=1 \
#     scripts/release/release.sh <version> --publish
# (the same as: git -c credential.helper= -c credential.helper='!gh auth git-credential' push <url> ...).
GIT_PUSH_URL="${GIT_PUSH_URL:-}"
GIT_USE_GH_CREDENTIALS="${GIT_USE_GH_CREDENTIALS:-0}"
# Author of the version-bump commit and tag created by --publish (the public repository uses a GitHub noreply
# address; the global git config is left untouched).
COMMIT_AUTHOR_NAME="${COMMIT_AUTHOR_NAME:-Kyle Zhang}"
COMMIT_AUTHOR_EMAIL="${COMMIT_AUTHOR_EMAIL:-1912137+kylezh@users.noreply.github.com}"

# ---- Code signing ------------------------------------------------------------------------------
# Both modes sign every executable with the Hardened Runtime (codesign --options runtime).
# selfsigned: sign with the self-signed identity in the login keychain, no notarization (current method).
#   Every release must use the same certificate and private key: macOS identifies the app by its signature, and
#   after a certificate change users must grant Accessibility / Screen Recording again.
# developer-id: sign with "Developer ID Application: <DEVELOPER_ID_NAME> (<TEAM_ID>)" with a secure timestamp, then
#   notarize the DMG with notarytool and staple the ticket. Switch-over steps: docs/releasing.md, "Switching to
#   Developer ID and notarization".
SIGNING_MODE="${SIGNING_MODE:-developer-id}"
SELF_SIGNED_IDENTITY="${SELF_SIGNED_IDENTITY:-Frost Local Signing}"
# Required by developer-id mode (ignored otherwise): the name and the 10-character Team ID exactly as they appear in
# the certificate's common name, "Developer ID Application: <name> (<team id>)" (security find-identity -v -p
# codesigning lists it). DEVELOPER_ID_IDENTITY defaults to that common name; set it only to pick the certificate
# some other way (e.g. by its SHA-1 hash when the keychain holds two certificates with the same name).
TEAM_ID="${TEAM_ID:-R974K7QN64}"
# The developer's name is not kept in the repository: when DEVELOPER_ID_NAME is unset it is read from the one
# "Developer ID Application: <name> (<TEAM_ID>)" certificate in the keychain.
if [[ -z "${DEVELOPER_ID_NAME:-}" ]]; then
  DEVELOPER_ID_NAME="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n "s/.*\"Developer ID Application: \(.*\) ($TEAM_ID)\".*/\1/p" | head -n 1)"
fi
DEVELOPER_ID_IDENTITY="${DEVELOPER_ID_IDENTITY:-Developer ID Application: $DEVELOPER_ID_NAME ($TEAM_ID)}"
# Keychain profile holding the notary credentials, created once with `xcrun notarytool store-credentials`.
NOTARY_PROFILE="${NOTARY_PROFILE:-frost-notary}"
# Entitlements per mode (relative to the repository root). The self-signed certificate has no Team ID, so library
# validation would reject Sparkle.framework: that mode needs com.apple.security.cs.disable-library-validation, which
# Developer ID signing doesn't (see the comments in both files).
SELF_SIGNED_ENTITLEMENTS="Frost/Resources/Frost-SelfSigned.entitlements"
DEVELOPER_ID_ENTITLEMENTS="Frost/Resources/Frost.entitlements"

# ---- Sparkle ----------------------------------------------------------------------------------
# The EdDSA private key lives in the login keychain (account name passed to generate_keys --account). Alternatively,
# set SPARKLE_KEY_FILE to an exported private key file (e.g. when releasing from another machine); the keychain is
# then not accessed.
SPARKLE_ACCOUNT="${SPARKLE_ACCOUNT:-dev.frost.Frost}"
SPARKLE_KEY_FILE="${SPARKLE_KEY_FILE:-}"

# ---- Paths ------------------------------------------------------------------------------------
DERIVED_DATA="$FROST_ROOT/build/DerivedData"
SPARKLE_BIN="$DERIVED_DATA/SourcePackages/artifacts/sparkle/Sparkle/bin"
RELEASE_ROOT="$FROST_ROOT/build/release"
# dmgbuild runs through uv (brew install uv), at a pinned version.
DMGBUILD=(uvx --quiet --from "dmgbuild==1.6.7" dmgbuild)
