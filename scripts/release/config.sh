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
# selfsigned: sign with the self-signed identity in the login keychain, no notarization (current method).
#   Every release must use the same certificate and private key: macOS identifies the app by its signature, and
#   after a certificate change users must grant Accessibility / Screen Recording again.
# developer-id: (optional, untested) Developer ID signing + hardened runtime + notarytool notarization + staple.
SIGNING_MODE="${SIGNING_MODE:-selfsigned}"
SELF_SIGNED_IDENTITY="${SELF_SIGNED_IDENTITY:-Frost Local Signing}"
# Required by developer-id mode (ignored otherwise):
DEVELOPER_ID_IDENTITY="${DEVELOPER_ID_IDENTITY:-Developer ID Application: YOUR NAME (TEAMID)}"
DEVELOPMENT_TEAM_ID="${DEVELOPMENT_TEAM_ID:-}"
# Name of the keychain credentials saved with `xcrun notarytool store-credentials <profile>`.
NOTARY_PROFILE="${NOTARY_PROFILE:-frost-notary}"

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
