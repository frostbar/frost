# Releasing Frost

Releases are DMGs on GitHub Releases, signed with a **Developer ID**, notarized by Apple and delivered to existing
users by **Sparkle 2**. Every executable uses the **Hardened Runtime**. Local self-signed builds remain available;
see [Developer ID and notarization configuration](#switching-to-developer-id-and-notarization).

```
CHANGELOG.md ──▶ scripts/release/release.sh <version> ──▶ build/release/<version>/
                   bump version → Release build (universal) → codesign (Hardened Runtime) + verify
                   → DMG (dmgbuild) → [developer-id: sign, notarize, staple the DMG]
                   → Sparkle EdDSA signature → appcast.xml
                   → [--publish] commit, tag, push, gh release create
                     (only after make vm-upgrade-test passed on the DMG a run without --publish built)
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
  (`origin`) as `REMOTE_BRANCH` (`main`) together with the tag, atomically, and authors its commit and tag as
  `COMMIT_AUTHOR_NAME` / `COMMIT_AUTHOR_EMAIL` (the GitHub noreply address) without touching your git config.
- **Pushing over HTTPS**: when the remote's SSH URL can't be used (e.g. the ssh agent is unavailable), set
  `GIT_PUSH_URL` to an HTTPS URL and `GIT_USE_GH_CREDENTIALS=1` so the credentials come from `gh`:

  ```sh
  GIT_PUSH_URL=https://<user>@github.com/<owner>/<repo>.git GIT_USE_GH_CREDENTIALS=1 \
    scripts/release/release.sh 0.2.0 --publish
  ```

  This is the same as `git -c credential.helper= -c credential.helper='!gh auth git-credential' push <url> …`;
  the fetch and tag checks of `--publish` use the same URL.
- **Signing**: `SIGNING_MODE=developer-id` (default), with `DEVELOPER_ID_NAME`, `TEAM_ID` and `NOTARY_PROFILE`;
  `selfsigned` is available for local builds. See
  [Switching to Developer ID and notarization](#switching-to-developer-id-and-notarization).

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
  identity and the Hardened Runtime by `release.sh`.

Sparkle removes the quarantine attribute from the update it installs, so updated copies open without the
Gatekeeper "Open Anyway" step.

## Hardened Runtime and entitlements

Notarization requires the Hardened Runtime on every executable, and Frost uses it everywhere already:
`ENABLE_HARDENED_RUNTIME: YES` in `project.yml` for Debug and Release, and `codesign --options runtime` in
`release.sh` for the app and each Sparkle helper (both signing modes). Check a build with
`codesign -dvv Frost.app` (`flags=0x10000(runtime)`) and `codesign -d --entitlements - --xml Frost.app`.

Frost needs **no** Hardened Runtime exception and no resource-access entitlement for what it does:

| Capability | What gates it |
| --- | --- |
| Synthesized CGEvents (⌘-drag moves routed through field `0x33`, clicks posted to the HID or session tap) | TCC: Accessibility (and the PostEvent grant macOS records for it); no entitlement |
| Accessibility API on other apps (`AXUIElement` reads, `AXPress`) | TCC: Accessibility |
| ScreenCaptureKit captures, window titles from `CGWindowList` | TCC: Screen Recording |
| Private window-list / CGS calls | none used |
| Apple Events, JIT, `DYLD_*` variables | none used (the `FROST_TEST_*` hooks are plain environment variables) |
| Sparkle updates (non-sandboxed host) | nothing in the host app; Downloader.xpc keeps its own (empty) entitlements via `--preserve-metadata=entitlements` |

Two entitlements files, chosen by the signing identity (each documents itself in comments):

- `Frost/Resources/Frost.entitlements` (Developer ID): `com.apple.security.app-sandbox = false` only.
- `Frost/Resources/Frost-SelfSigned.entitlements` (every Xcode build, `SIGNING_MODE=selfsigned`): the same plus
  `com.apple.security.cs.disable-library-validation`. Library validation only lets a hardened process load code
  signed by Apple or by its own **Team ID**, and a self-signed certificate has no Team ID: even Sparkle.framework
  signed with the very same certificate is rejected ("mapping process and mapped file (non-platform) have different
  Team IDs") and Frost would not launch. With a Developer ID certificate the app and the framework share the Team ID,
  so `release.sh` signs Developer ID releases with `Frost.entitlements` and the exception disappears.

`release.sh` checks the result: every Mach-O file in the bundle is signed by the release identity with the runtime
flag (for Developer ID also with the Team ID and a secure timestamp), the app has no `get-task-allow`, and its runtime
exceptions are exactly those of the mode's entitlements file.

Debug builds keep the Hardened Runtime too, so tests in the VM run under the same restrictions as releases; Xcode
still injects `com.apple.security.get-task-allow` into Debug builds (lldb can attach), and the Debug-only
`Frost.debug.dylib` is covered by the same library validation exception. **The test VM can't catch library
validation problems**: it runs with SIP disabled, where library validation isn't enforced. That the exception is
needed (and sufficient) was measured on a Mac with SIP enabled with a command-line probe that loads the release's
Sparkle.framework, not by launching Frost.

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
   OpenSSL (OpenSSL 3 is looked up: `$OPENSSL`, Homebrew's `openssl@3`, then `PATH`; the system's LibreSSL can't
   verify Ed25519), and writes `appcast.xml` and `release-notes.md`. The version bump stays uncommitted in
   `project.yml` and `Frost/Resources/Info.plist` (the script says so); at the end it prints how to publish.
4. Run the **upgrade test** on this DMG in the VM ([`testing-vm.md`](testing-vm.md), "Upgrade test"):

   ```sh
   make vm-upgrade-test BUILD=build/release/0.2.0/Frost-0.2.0.dmg
   ```

   It installs the newest published release, lets it build up real state (sections, seen icons, the image cache),
   installs this DMG over it and checks that it keeps running without a crash and keeps or migrates everything. On a
   pass it writes `build/upgrade-test/passed/<version>-<build>.txt` (`UPGRADE_TEST_MARKERS` in `config.sh`) with the
   DMG's SHA-256 and the source identity (commit plus uncommitted changes, i.e. the version bump) that `release.sh`
   recorded in `build/release/<version>/build-info.txt`. Rebuilding the DMG invalidates it.
5. Walk all journeys in [`ux-journeys.md`](ux-journeys.md) on this build; fix High findings before
   publishing. Optionally test the update in the VM (below).
6. Publish, on branch `RELEASE_BRANCH` with `gh auth login` done:

   ```sh
   scripts/release/release.sh 0.2.0 --publish
   ```

   Before building, the preflight checks that `gh` is logged in, fetches `REMOTE_BRANCH` and requires the local
   branch to contain it (`git merge-base --is-ancestor`), and checks that the tag exists neither locally nor on the
   remote (`git ls-remote --tags`). It **refuses to publish** unless the upgrade test passed for exactly this release
   candidate: the marker for the version and build in `project.yml` must exist, name the SHA-256 of
   `build/release/<version>/Frost-<version>.dmg`, and carry the current tree's source identity (so a commit or any
   other change after the test needs a new candidate and a new test). It then rebuilds from those same sources, notes
   whether the rebuilt app has the tested CDHash (the build isn't guaranteed to be bit-for-bit reproducible), commits
   the version bump, tags `v0.2.0`, pushes branch and tag with `git push --atomic` (both land or neither does), and
   runs `gh release create v0.2.0 --verify-tag … Frost-0.2.0.dmg appcast.xml`.

   **Emergencies only**: `--skip-upgrade-test` publishes without the test. It prints a red warning before building
   and again after publishing; run the upgrade test on the published DMG (`make vm-upgrade-test BUILD=v0.2.0`) right
   after.

The working tree must be clean, except for exactly the version bump a previous run of the script left in
`project.yml` / `Info.plist` (so "build locally, inspect, then `--publish`" works; the bump is reused, keeping the
build number). `--allow-dirty` builds from an uncommitted tree for local experiments (never with `--publish`).
A failed run reports what it leaves behind: an uncommitted version bump (rerunning reuses it; `git checkout --
project.yml Frost/Resources/Info.plist` undoes it), or, if the push was rejected, the release commit on the branch
(the local tag is deleted, nothing is pushed: pull and rerun `--publish`). If only `gh release create` fails after
the push, the script prints the command to create the release.

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
   shows no quarantine. `codesign -dvv /Applications/Frost.app` should still show `flags=0x10000(runtime)`.
4. `defaults delete dev.frost.Frost SUFeedURL` afterwards.

## Switching to Developer ID and notarization

Developer ID signing and notarization are the default release configuration. The steps below describe setting up
another release environment. Keep the existing signing identity and Sparkle key unchanged so updates preserve
permissions and remain verifiable.

### One-time setup

1. **Create the certificate.** Xcode → Settings → Accounts → add the Apple ID of the developer account → select the
   team → **Manage Certificates…** → **+** → **Developer ID Application** (only the account holder can create it). It
   lands in the login keychain. Check it, and read the Team ID (the 10 characters in parentheses):

   ```sh
   security find-identity -v -p codesigning   # "Developer ID Application: <Name> (<TEAMID>)"
   ```

   Back it up like the self-signed one: Keychain Access → My Certificates → export it **with its private key** as a
   password-protected `.p12`, stored outside the repository. Never commit it.
2. **Store the notary credentials** in the keychain under the profile name `frost-notary`. Create an app-specific
   password at account.apple.com → Sign-In and Security → App-Specific Passwords, then:

   ```sh
   xcrun notarytool store-credentials frost-notary --apple-id <apple id> --team-id <TEAMID>
   # prompts for the app-specific password; an App Store Connect API key works too (--key, --key-id, --issuer)
   ```

3. **Configure** [`scripts/release/config.sh`](../scripts/release/config.sh) (or the environment): set
   `SIGNING_MODE` to `developer-id`, `DEVELOPER_ID_NAME` to the name and `TEAM_ID` to the Team ID exactly as in the
   certificate's name (both are public: they are part of every signed app). `DEVELOPER_ID_IDENTITY` is derived from
   them; `NOTARY_PROFILE` defaults to `frost-notary`.
4. **Validate** without building or submitting anything:

   ```sh
   scripts/release/release.sh --dry-run-notarize
   ```

   It checks that `TEAM_ID` looks right, the identity is valid in the keychain and belongs to `TEAM_ID`, `notarytool`
   and `stapler` are available, and the notary credentials work (`notarytool history`), then prints the plan.
5. Keep `SUPublicEDKey` and the Sparkle EdDSA key unchanged: they are what lets existing self-signed installs accept
   the first Developer ID release (below). Local Xcode builds (`make build`, `make vm-deploy`) keep using
   "Frost Local Signing"; that is fine.

### What a Developer ID release does

`scripts/release/release.sh <version>` in `developer-id` mode follows Apple's flow for apps distributed in a disk
image:

1. builds the Release app with the Developer ID identity, then re-signs inside-out (Sparkle's Installer.xpc,
   Downloader.xpc with `--preserve-metadata=entitlements`, Autoupdate, Updater.app, Sparkle.framework, then Frost.app
   with `Frost.entitlements`) with `--options runtime --timestamp`; no `--deep`;
2. verifies with `codesign --verify --deep --strict` and checks every executable for the identity, Team ID, runtime
   flag and secure timestamp, and the entitlements (no `get-task-allow`, no runtime exceptions);
3. builds the DMG and signs it (`codesign --timestamp`);
4. submits the **DMG** with `xcrun notarytool submit --keychain-profile frost-notary --wait`; the notary log is
   always saved to `build/release/<version>/notarization/notary-log.json`, and a rejected submission stops the
   release with the log printed (it lists every problem with its path);
5. staples the ticket to the DMG (`xcrun stapler staple`), checks it with `stapler validate` and
   `spctl -a -t open --context context:primary-signature` (must say `source=Notarized Developer ID`), mounts it and
   checks the app inside with `spctl -a -t exec`;
6. only then computes the Sparkle EdDSA signature: stapling modifies the DMG, so the appcast must describe the
   stapled file. The stapled DMG is both the download and Sparkle's update archive.

The app itself is not notarized or stapled separately: the notary service checks everything inside the DMG and the
ticket covers all of its code. A copy dragged to /Applications passes Gatekeeper through the online ticket lookup,
and offline as well once the stapled DMG has been opened on that Mac. Sparkle updates don't go through Gatekeeper at
all (Sparkle removes the quarantine attribute).

### The first notarized release

1. `scripts/release/release.sh <version>` and look at the output (the notarization step takes a few minutes).
2. Test the update in the VM from the last self-signed release to the new one (see
   [Testing an update in the VM](#testing-an-update-in-the-vm)). The new signature has a different designated
   requirement, so the VM's TCC rows no longer match: run `scripts/vm/vm-grant-tcc.sh` after the update (it reads
   the requirement from the installed app). Before that, check that Frost reports the permissions as missing.
3. Update `README.md`: the installation steps about "Open Anyway" and `xattr` no longer apply to notarized
   releases; downloading, opening the DMG and dragging Frost to Applications is enough.
4. Write the release notes with the permission note below, then publish with `--publish`.

### Permissions after the switch (one time, for every user)

macOS remembers Accessibility and Screen Recording grants by the app's **designated requirement**. A self-signed
build's requirement pins the certificate (`certificate leaf = H"…"`); a Developer ID build's requirement is Apple's
anchor plus the Team ID. Sparkle installs the first Developer ID release fine (its EdDSA signature verifies against
the unchanged `SUPublicEDKey`), but after that update macOS treats Frost as a different app:

- Frost relaunches without its permissions: hiding and showing keep working, the Frost Bar and the layout editor ask
  for the permissions again (the About tab shows **Grant**).
- System Settings → Privacy & Security still lists Frost under Accessibility and Screen & System Audio Recording,
  possibly switched on, but those entries belong to the old signature. Remove Frost from both lists (select it,
  **−**) and grant again through Frost, or switch the entry off and on. Screen Recording takes effect after
  relaunching Frost. In Terminal: `tccutil reset Accessibility dev.frost.Frost` and
  `tccutil reset ScreenCapture dev.frost.Frost`, then grant again.

This happens exactly once. The Developer ID requirement names the Team ID rather than one certificate, so later
releases, including ones signed with a renewed Developer ID certificate, keep the grants. Say so in the first
notarized release's notes (they appear in Sparkle's update window).

### Verifying a notarized DMG on a clean Mac

On a Mac (or a fresh VM) that has never run Frost, download the DMG from the GitHub release with a browser (so it
carries the quarantine attribute), then:

```sh
spctl -a -t open --context context:primary-signature -v Frost-<version>.dmg   # accepted, source=Notarized Developer ID
xcrun stapler validate Frost-<version>.dmg                                    # The validate action worked!
hdiutil attach Frost-<version>.dmg
spctl -a -t exec -vv /Volumes/Frost/Frost.app                                 # accepted, source=Notarized Developer ID
codesign -dvv /Volumes/Frost/Frost.app     # flags=0x10000(runtime), TeamIdentifier=<TEAMID>, Timestamp=…
```

Then drag Frost to Applications and open it: macOS shows only the usual "downloaded from the Internet" confirmation,
with no trip to Privacy & Security. For the stapled ticket, repeat with the network disconnected before opening the
DMG. (`stapler validate` on the app inside reports no ticket; that is expected, only the DMG is stapled.)

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
  signing disabled, the same command as `make ci-build`. Package versions come only from the committed
  `Package.resolved` (`-onlyUsePackageVersionsFromResolvedFile`; Sparkle is pinned with `exactVersion` in
  `project.yml`), as in `release.sh`. CI has no "Frost Local Signing" identity, so this build is
  only a compile check; the unsigned app is kept as a workflow artifact for 7 days and must never be published.
- **Lint**: no CJK text outside `*.xcstrings`, `shellcheck` (warnings and errors) on all tracked `*.sh` files, and no
  committed certificates or private keys. The grep-based checks run in a UTF-8 locale and fail when `grep` itself
  fails (exit status 2 or more), not only when it finds a match.

The macOS jobs run on the `xcode-27` runner image (a GitHub public preview) with Xcode 27.0 selected through
`DEVELOPER_DIR` in the workflow; when a newer Xcode is needed, change it there. The checks are **informational**: they
are not required status checks in the `main` ruleset, because development pushes directly to `main` and a required
check would block those pushes. Look at the badge in `README.md` or the Actions tab after pushing.
