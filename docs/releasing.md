# Releasing Frost

Releases are DMGs on GitHub Releases, signed with the self-signed identity **"Frost Local Signing"** (no Apple
Developer account, no notarization) and delivered to existing users by **Sparkle 2**.

```
CHANGELOG.md ──▶ scripts/release/release.sh <version> ──▶ build/release/<version>/
                   bump version → Release build (universal) → codesign + verify
                   → DMG (dmgbuild) → Sparkle EdDSA signature → appcast.xml
                   → [--publish] commit, tag, push, gh release create
```

Users' copies check `https://github.com/<owner>/<repo>/releases/latest/download/appcast.xml` once a day, so the
appcast attached to the **latest** (non-prerelease) GitHub release is the update feed.

## Configuration

Everything lives in [`scripts/release/config.sh`](../scripts/release/config.sh); each value can be overridden with an
environment variable of the same name.

- **GitHub repository**: `FROST_GITHUB_REPO` in [`project.yml`](../project.yml) (currently `frostbar/frost`) is the
  single source. Info.plist's `SUFeedURL` is built from it and `config.sh` reads it. When the repository moves, change
  that line (and the two Releases links in `README.md`), then ship a release from the old location first so that
  existing installs learn the new feed URL.
- **Publishing**: `--publish` pushes the local branch `RELEASE_BRANCH` (default `main`) to `GIT_REMOTE`
  (`origin`) as `REMOTE_BRANCH` (`main`) and authors its commit and tag as `COMMIT_AUTHOR_NAME` /
  `COMMIT_AUTHOR_EMAIL` (the GitHub noreply address) without touching your git config.
- **Signing**: `SIGNING_MODE=selfsigned` (default) or `developer-id` (see below).

## Keys and certificates

Two private keys make releases work. **Neither may ever be committed**, and both must be backed up: losing them
breaks updates or permissions for every existing user.

| | Self-signed certificate "Frost Local Signing" | Sparkle EdDSA key |
| --- | --- | --- |
| Where | login keychain (certificate + RSA private key), created by `scripts/create-signing-cert.sh` | login keychain, generic password "Private key for signing Sparkle updates", account `dev.frost.Frost` |
| Public part | the certificate (its hash is in the app's designated requirement) | `SUPublicEDKey` in `project.yml` |
| Used for | codesigning the app | signing each DMG (`sparkle:edSignature` in the appcast) |
| If it changes | macOS treats the update as a different app: users must grant Accessibility and Screen Recording again | Sparkle rejects the update unless the code signature still matches (see below) |
| If both are lost | users can't auto-update; they must download the new version manually | |

### Back up the signing certificate

Export it **with its private key** as a password-protected `.p12`, stored outside the repository (password manager or
an encrypted volume):

1. Keychain Access → login → My Certificates → **Frost Local Signing** (expand it: the private key must be included).
2. File → Export Items… → format **Personal Information Exchange (.p12)** → save outside the repository → set a
   strong password.

Restore on another Mac: `security import Frost-Local-Signing.p12 -k ~/Library/Keychains/login.keychain-db -T /usr/bin/codesign`,
then trust it for code signing (Keychain Access → Trust → Code Signing: Always Trust). **Do not** run
`create-signing-cert.sh` on a new machine for releases: it would create a different certificate.

### Back up the Sparkle key

The Sparkle tools are downloaded by SwiftPM into `build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/`
(run `make build` once).

```sh
BIN=build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin
$BIN/generate_keys --account dev.frost.Frost -p                       # print the public key (= SUPublicEDKey)
$BIN/generate_keys --account dev.frost.Frost -x ~/frost-sparkle-key   # export the private key
# store the file's contents in a password manager, then: rm ~/frost-sparkle-key
$BIN/generate_keys --account dev.frost.Frost -f ~/frost-sparkle-key   # import it on another Mac
```

To sign without the keychain (e.g. on another machine), set `SPARKLE_KEY_FILE=/path/to/exported-key`.

### Why updates work without a Developer ID

Sparkle (2.10, non-sandboxed app) accepts an update when **either** check passes
(`SUUpdateValidator`): the DMG's EdDSA signature verifies against the `SUPublicEDKey` of the **installed** app, **or**
the new app's code signature satisfies the installed app's designated requirement. If the EdDSA check passes, the new
app must still have a valid (not necessarily Apple-issued) code signature. Neither check needs a Developer ID or
notarization, and the installer's XPC connection check only applies when the app has a Team ID (a self-signed app has
none). In practice:

- keep `SUPublicEDKey` and the EdDSA key unchanged, and keep signing with "Frost Local Signing";
- never ship an unsigned or ad-hoc-signed build (Sparkle refuses to replace a signed app with an unsigned one);
- the Sparkle helpers inside the framework (Autoupdate, Updater.app, XPC services) are re-signed with the same
  identity by `release.sh`.

Sparkle removes the quarantine attribute from the update it installs, so updated copies open without the
Gatekeeper "Open Anyway" step.

## Making a release

1. Add a `## [x.y.z] - YYYY-MM-DD` section at the top of [`CHANGELOG.md`](../CHANGELOG.md). It is used verbatim as
   the GitHub release notes and in Sparkle's update window (Markdown).
2. Commit everything; `make test-core && make build` must pass.
3. Build and inspect the release locally (nothing is uploaded):

   ```sh
   scripts/release/release.sh 0.2.0      # or: make dist VERSION=0.2.0
   ```

   It bumps `CFBundleShortVersionString` to `0.2.0` and `CFBundleVersion` by one in `project.yml` (Sparkle compares
   `CFBundleVersion`), builds a universal Release app, re-signs it inside-out, checks the signature, identity,
   `SUFeedURL` and `SUPublicEDKey`, builds `Frost-0.2.0.dmg` (with
   [dmgbuild](https://github.com/dmgbuild/dmgbuild) through `uvx`; a plain DMG without `uv`), mounts it to check the
   app inside, signs the DMG with the EdDSA key, verifies that signature against the app's `SUPublicEDKey` with
   OpenSSL, and writes `appcast.xml` and `release-notes.md`. At the end it prints the exact commands that would
   publish it.
4. Optionally test the update in the VM (below).
5. Publish, on branch `RELEASE_BRANCH` with a clean tree and `gh auth login` done:

   ```sh
   scripts/release/release.sh 0.2.0 --publish
   ```

   This commits the version bump, tags `v0.2.0`, pushes branch and tag, and runs
   `gh release create v0.2.0 --verify-tag … Frost-0.2.0.dmg appcast.xml`.

`--allow-dirty` builds from an uncommitted tree for local experiments (never with `--publish`). Running the script
twice for the same version keeps the build number.

## Testing an update in the VM

The feed URL can be overridden per user: Sparkle reads `SUFeedURL` from the app's user defaults before Info.plist.
Never test on the host desktop (see `AGENTS.md`).

1. Build two versions, e.g. `0.1.0` and `0.1.1` (the second in a scratch worktree with a `## [0.1.1]` section in
   its CHANGELOG, using `--allow-dirty`).
2. In the guest: install `0.1.0` into `/Applications` from its DMG by dragging it in Finder (a VNC drag works), or
   remove the quarantine attribute afterwards. A quarantined copy made with `cp` / `ditto` runs translocated (from a
   random read-only path) and Sparkle cannot update it. Copy the `0.1.1` DMG and appcast next to each other in a
   folder, point the enclosure URL at a local server and serve it:

   ```sh
   sed -i '' 's#url="[^"]*"#url="http://127.0.0.1:8000/Frost-0.1.1.dmg"#' appcast.xml
   python3 -m http.server 8000 --bind 127.0.0.1 &
   defaults write dev.frost.Frost SUFeedURL http://127.0.0.1:8000/appcast.xml
   ```

3. Launch Frost, choose **Check for Updates…** from the snowflake's right-click menu, install, relaunch, and check
   the version in Settings → About, that permissions are still granted, and that `xattr /Applications/Frost.app`
   shows no quarantine.
4. `defaults delete dev.frost.Frost SUFeedURL` afterwards.

## Optional: Developer ID and notarization (untested)

With an Apple Developer account, set in the environment (or `config.sh`):

```sh
SIGNING_MODE=developer-id
DEVELOPER_ID_IDENTITY="Developer ID Application: Your Name (TEAMID)"
DEVELOPMENT_TEAM_ID=TEAMID
NOTARY_PROFILE=frost-notary   # created once with: xcrun notarytool store-credentials frost-notary --apple-id … --team-id …
```

`release.sh` then builds with the hardened runtime, signs with `--options runtime --timestamp`, signs the DMG,
submits it with `notarytool --wait`, staples it and checks it with `spctl` before the EdDSA signature is made. This
path has not been exercised yet. Switching identities is a one-time change for users: Sparkle accepts the update
because the EdDSA key is unchanged, but macOS sees a new code signature, so Accessibility and Screen Recording must be
granted again once.

## Repository protection

`frostbar/frost` uses two repository rulesets (Settings → Rules → Rulesets):

- **Protect main** (default branch), enforced for everyone including admins: no deletion, no force pushes, linear
  history. Development is direct pushes (no pull requests), so every push to `main` must be a fast-forward —
  `release.sh --publish` adds one commit on top of the published history, which satisfies this.
- **Protect release tags** (`v*`): tags can't be deleted, moved or force-updated. Organization admins can bypass this
  one to repair a botched release.

## Continuous integration

[`.github/workflows/ci.yml`](../.github/workflows/ci.yml) runs on every push to `main`, on pull requests and on
demand (Actions → CI → Run workflow):

- **FrostCore tests**: `swift test` in `Packages/FrostCore`.
- **App build (unsigned)**: `xcodegen generate` + a Release build for `generic/platform=macOS` (universal) with code
  signing disabled, the same command as `make ci-build`. CI has no "Frost Local Signing" identity, so this build is
  only a compile check; the unsigned app is kept as a workflow artifact for 7 days and must never be published.
- **Lint**: no CJK text outside `*.xcstrings`, `shellcheck` (warnings and errors) on all tracked `*.sh` files, and no
  committed certificates or private keys.

The macOS jobs run on the `xcode-27` runner image (a GitHub public preview) with Xcode 27.0 selected through
`DEVELOPER_DIR` in the workflow; when a newer Xcode is needed, change it there. The checks are **informational**: they
are not required status checks in the `main` ruleset, because development pushes directly to `main` and a required
check would block those pushes. Look at the badge in `README.md` or the Actions tab after pushing.
