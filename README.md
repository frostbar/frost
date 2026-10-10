<p align="center">
  <img src="Frost/Resources/Assets.xcassets/AppIcon.appiconset/icon_256.png" width="128" alt="Frost icon">
</p>

<h1 align="center">Frost</h1>

<p align="center">
  <strong>A menu bar manager for macOS 26 and 27, built with Liquid Glass.</strong><br>
  Hide the menu bar icons you rarely use. Bring them back with one click.
</p>

<p align="center">
  <a href="https://github.com/frostbar/frost/releases/latest"><img src="https://img.shields.io/github/v/release/frostbar/frost?label=download&color=2f7bf5" alt="Download the latest release"></a>
  <img src="https://img.shields.io/badge/macOS-26%20%7C%2027-black" alt="macOS 26 and macOS 27">
  <img src="https://img.shields.io/badge/notarized-Developer%20ID-success" alt="Signed with a Developer ID and notarized by Apple">
  <a href="https://github.com/frostbar/frost/actions/workflows/ci.yml"><img src="https://github.com/frostbar/frost/actions/workflows/ci.yml/badge.svg?branch=main" alt="CI"></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/frostbar/frost" alt="MIT license"></a>
</p>

<p align="center">
  <img src="docs/images/demo.gif" width="720" alt="Demo: clicking the snowflake opens the Frost Bar with the hidden menu bar icons; clicking one opens its menu in the menu bar, and after Esc it hides again">
</p>

<details>
<summary><strong>macOS 27 demo</strong></summary>

<img src="docs/images/macos27-demo.gif" width="720" alt="macOS 27: clicking the snowflake opens the Frost Bar; clicking a hidden weather icon moves it beside the snowflake, moves the pointer onto it and opens its native menu; moving away returns it">

The same Frost Bar and Settings interface, with the macOS 27 differences listed below.

</details>

## Why Frost

- **Made for the notch.** On a MacBook with a notch, icons that don't fit simply disappear behind it. Frost keeps
  them in the **Frost Bar**, a glass panel that drops down below the menu bar, and opens any of them with one click.
- **Feels native.** Liquid Glass, smooth animations, no flicker, English and Simplified Chinese.
- **Stays out of your way.** No accounts, no analytics, no pop-ups. Open source under the MIT license.

## Features

- **Three sections:** Visible, Hidden and Always Hidden. Click the snowflake to show Hidden; ⌥-click to show Always
  Hidden too. Optionally hide them again after a delay. On macOS 27, sections follow the arrangement you set in
  Layout (see [Known limitations](#known-limitations)).
- **Frost Bar:** menu bar icons in a glass grid. Click an icon to open its menu. On macOS 26, images refresh while
  the panel is open, and right-click, Control-click and ⌥-click are supported. On macOS 27, a primary click
  temporarily moves the hidden icon beside the snowflake, leaves the pointer on it and returns it after its menu
  closes and the pointer moves away. Images refresh when the panel opens and while editing the layout.
- **Layout editor:** drag icons between sections or change their order; each drop moves the actual menu bar icon.
  Optional Screen Recording adds captured images on both macOS versions.
- **Keep icons in their sections (macOS 26):** new apps' icons go to Hidden, and when an app relaunches and macOS
  puts its icon somewhere else, Frost moves it back. On macOS 27, Frost remembers the sections you set in Layout.
- **Display modes:** Automatic (the Frost Bar on displays with a notch, in the menu bar elsewhere), In Menu Bar, or
  Frost Bar.
- **Multiple displays, launch at login, automatic updates** with a quiet reminder dot instead of pop-ups.

Hiding and showing icons needs **no permissions**. The Frost Bar and the layout editor need only **Accessibility**;
Screen Recording is optional and shows real images of the icons.

| Settings → Layout | Settings → About |
| --- | --- |
| <img src="docs/images/layout-editor.png" width="420" alt="The layout editor with Visible, Hidden and Always Hidden sections"> | <img src="docs/images/about.png" width="420" alt="The About tab with update settings and the status of the Accessibility and Screen Recording permissions"> |

## Install

Requires **macOS 26 Tahoe** or **macOS 27** (Apple silicon or Intel). Both use the same Frost Bar and Settings
interface; see [Known limitations](#known-limitations) for the macOS 27 differences.

1. Download **`Frost-<version>.dmg`** from the [latest release](https://github.com/frostbar/frost/releases/latest).
2. Open it and drag **Frost** to **Applications** in Finder.
3. Open Frost. It's signed with a Developer ID and notarized by Apple, so it opens like any other app; onboarding then
   asks for Accessibility (and, optionally, Screen Recording; see below).

Install by dragging in Finder: a copy made another way (e.g. `cp` from the disk image) runs from a temporary read-only
location and can't update itself.

<details>
<summary><strong>Upgrading from 0.1.x</strong></summary>

0.2.0 is the first release signed with a Developer ID, so macOS asks once more for Accessibility and Screen Recording
after the update. If a switch in **System Settings → Privacy & Security** looks on but Frost still asks, remove the old
Frost entry and grant it again. Later updates keep the permissions.

</details>

## Permissions

| Permission | | Used for | Without it |
| --- | --- | --- | --- |
| Accessibility | Required | Identifying icons, moving them in Layout and opening them from the Frost Bar; on macOS 26, also keeping relaunched icons in their sections | The Frost Bar and layout editor ask for it; hiding and showing still work (hidden icons expand in the menu bar) |
| Screen Recording | Optional | Real icon images in the Frost Bar and Layout. On macOS 26 they refresh while the Frost Bar is open; on macOS 27 they refresh when it opens and while editing. Icons that cannot be captured keep their app icon | Everything still works; icons are shown as their app's icon (or a system symbol), with a short label where it helps tell them apart |

Onboarding opens on first launch. **Settings → About** shows each permission's status, and **Grant Access** asks for
it right away (the system prompt, or System Settings if there is no prompt). Without Screen Recording, the Frost Bar
and the layout editor offer it in a small hint you can close. Frost has to be relaunched after granting Screen
Recording: a **Relaunch** button (next to **Open System Settings**) appears right where you granted it, and Frost
reopens the window you were in.

## Updates and privacy

- Frost checks for updates once a day with [Sparkle](https://sparkle-project.org) and installs nothing without asking.
  When an update is available, a dot appears on the snowflake and its right-click menu shows **Update Available…**.
  You can check manually (**Settings → About** also shows when Frost last checked) or turn automatic checks off
  there. Updates are verified with an EdDSA signature.
- The update check is Frost's only network access: it downloads `appcast.xml` (and the update, if you accept it) from
  this repository's GitHub Releases. No analytics, no accounts.
- Menu bar icon images are used only for display and cached in `~/Library/Caches/dev.frost.Frost/items/` (entries not
  seen for 30 days are removed). You can delete the folder at any time.

## Known limitations

- **macOS 27:** sections remember the arrangement you set in Layout; they do not certify which icons macOS
  currently draws. The Frost Bar lists your configured Hidden items (plus Always Hidden on Option-click),
  without a hidden-item count. Forwarding briefly reveals the menu bar to move an item out and back. Primary clicks
  are supported; right-click, Control-click and Option-click forwarding are unavailable. Captured images refresh when the panel
  opens and while editing, rather than continuously while the panel stays open; items that cannot be captured keep
  their app icon. Frost remembers your sections but does not automatically move relaunched icons back into them.
  Hiding and forwarding have been verified on one unnotched display; notched hardware and multiple displays still
  need verification on this backend.
- On macOS 28 and later, Frost leaves the menu bar alone and shows an unsupported-version notice.
- With several displays, Frost manages the menu bar you last clicked; the other displays show macOS's copies of it.
- On macOS 26, macOS doesn't draw icons behind the notch, so Frost gets their images with a short background
  capture: while you aren't using the menu bar, it moves one such icon next to the snowflake under a still image of
  the menu bar and puts it straight back (with Screen Recording granted). Until then they show their app icon, and
  images that change (a timer, a temperature) are only refreshed occasionally. The menu bar also briefly collapses
  while such an icon is moved in the layout editor.
- Frost has no global hotkeys, hover or scroll triggers, menu bar styling, or icon search.

## Build from source

Requires Xcode 27 (Swift 6.4), [XcodeGen](https://github.com/yonaskolb/XcodeGen) and OpenSSL 3
(`brew install xcodegen openssl`).

```sh
./scripts/create-signing-cert.sh   # once: a self-signed "Frost Local Signing" identity for Debug builds
make build                         # Debug build: build/DerivedData/Build/Products/Debug/Frost.app
make test-core                     # unit tests (Swift Testing)
make install                       # Release build (Developer ID if you have one), installed to /Applications
make ci-build                      # unsigned universal Release build, as run by CI
```

A stable signing identity keeps macOS from asking for permissions after every rebuild. If `codesign` says the
certificate isn't trusted, open Keychain Access → "Frost Local Signing" → Trust → Code Signing: Always Trust.

Frost moves and clicks real menu bar icons, so GUI testing happens in a macOS VM ([`docs/testing-vm.md`](docs/testing-vm.md)).
Releases are described in [`docs/releasing.md`](docs/releasing.md); contributor notes are in [`AGENTS.md`](AGENTS.md).
Found a bug? [Open an issue](https://github.com/frostbar/frost/issues/new/choose).

## Acknowledgements

Frost's approach (pushing icons off screen with wide separator items) follows the open-source
[Ice](https://github.com/jordanbaird/Ice). Updates use [Sparkle](https://sparkle-project.org).

## License

[MIT](LICENSE)
