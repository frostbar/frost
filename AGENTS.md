# AGENTS.md

Instructions for AI coding agents working in this repository. User documentation is in `README.md`.

## Project

Frost: a macOS menu bar manager (similar to [Ice](https://github.com/jordanbaird/Ice)) that hides menu bar items and
shows the hidden ones in a glass panel below the menu bar (the Frost Bar).

- Supports **macOS 26+** only (Liquid Glass); no compatibility with older systems.
- Stack: Swift 6.4 (Swift 6 language mode, `SWIFT_STRICT_CONCURRENCY: complete`), Xcode 27, SwiftUI + AppKit,
  XcodeGen, Sparkle 2 (SPM, automatic updates).
- Not sandboxed, distributed directly; needs the Accessibility and Screen Recording permissions. Basic hiding and
  showing needs no permissions at all.

## Common commands

```bash
./scripts/create-signing-cert.sh   # once: create the local signing identity "Frost Local Signing"
make test-core                     # FrostCore unit tests (Swift Testing)
make build                         # xcodegen generates the project + xcodebuild (Debug, arm64)
make ci-build                      # unsigned universal Release build, the same command CI runs
make vm-deploy && make vm-run      # deploy and run in the test VM (see below)
scripts/release/release.sh 0.2.0   # package a release locally (DMG + appcast) without publishing; see docs/releasing.md
```

`Frost.xcodeproj` is generated from `project.yml` and is gitignored: change project settings in `project.yml`. The one
exception is the SwiftPM pin file `Frost.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`, which
XcodeGen preserves and which is committed (Sparkle is pinned with `exactVersion`; `make ci-build` and releases only use
the committed pins). When changing a package version, commit the updated `Package.resolved` from `make build`.

Before finishing any change, `make test-core` and `make build` must both pass without new warnings.

## Layout

- `Packages/FrostCore/`: logic and system adapter layer; all testable pure logic goes here (Swift Testing,
  `import Testing`, not XCTest).
  - `Model/`: `MenuBarItem`, sections and section state, screen geometry (`NSScreen.displayID`, `ScreenCoordinates`)
  - `Scanning/`: merges CGWindowList (layer 25) + Accessibility into `MenuBarItem`; multi-display resolution
  - `Layout/`: section classification, drop indices, layout reconciliation, panel positioning, placement of new items
  - `Moving/`: ⌘-drag moves (`ItemMover`), click forwarding (`ItemClicker`), restore plans, activation handoff
  - `Capture/`: ScreenCaptureKit captures, glyph brightness, the disk cache, live refresh policy
  - `Permissions/`
- `Frost/`: app layer. `Sections/SectionController` (the three status items and the section state machine),
  `FrostBar/` (`FrostBarController` is split into panel, `+LiveRefresh` and `+Forwarding` files), `Settings/`
  (including the layout editor), `Onboarding/`, `Support/` (preferences, `EventMonitors`, the Debug-only `FrameProbe`),
  `App/` (`AppModel` wires the components and navigation callbacks together). `Resources/Localizable.xcstrings`: the
  String Catalog (English base, zh-Hans).
- `Tools/FakeItems/`: a fake third-party menu bar app for testing (VM testing only).
- `scripts/vm/`: VM testing scripts. `scripts/release/`: release scripts (`config.sh` is the single release
  configuration). `Spikes/`: early proof-of-concept programs, not part of the build.
- `docs/plans/`: the design document and `spike-findings.md` (measured macOS 26 behavior; read it before changing
  low-level code).
- `docs/manual-test-checklist.md` (including "Known limitations"), `docs/testing-vm.md` (including "Verification
  techniques"), `docs/releasing.md` (releases, signing and keys).

## Hard rules

1. **No GUI testing on the user's real desktop**: do not launch Frost.app on the host, create status items,
   synthesize mouse/keyboard events, move the cursor or capture the host screen. The menu bar is shared by the whole
   login session, and any such test disturbs the user. On the host, only `make test-core`, `make build`, unit tests
   and **offscreen** rendering (no visible windows) are allowed.
2. **All real GUI verification happens in the tart VM `frost-test`**, see `docs/testing-vm.md`:
   `make vm-up / vm-deploy / vm-run / vm-shot / vm-logs / vm-down`. `scripts/vm/vm-vnc.sh` sends input to the VM
   only (in VNC, `alt` = ⌘ and `meta` = ⌥; drags in the editor need the in-guest `guest-drag` tool). The VM has no
   notch. tart gives a macOS guest only one display; the second one is an in-guest virtual display
   (`scripts/vm/guest-virtual-display.m`, which exists as long as its process runs). It is not visible in the VNC
   framebuffer; capture it with `screencapture -D 2` inside the guest.
3. **Safety constraints for synthesized events**: when moving items, the mouse-down must physically land on the center
   of Frost's own item and is routed to the target item by window ID through event field `0x33`. Never post a ⌘
   mouse-down at the position of a third-party item. Restore the cursor position after every synthesized event.
4. Do not call `NSStatusBar.removeStatusItem` on quit: it deletes the item's saved Preferred Position.
5. **Never commit private keys or certificates** (the Sparkle EdDSA private key, the .p12 of "Frost Local
   Signing"). Do not casually change the release signing identity or `SUPublicEDKey`; see `docs/releasing.md` for
   why.
6. Docs, comments and test data must not contain personal environment details (real app names, host names,
   accounts, absolute paths, etc.); use neutral descriptions ("a third-party menu app"). Commits to the public
   repository use the GitHub noreply address as author (`COMMIT_AUTHOR_*` in `scripts/release/config.sh`).

## Key facts on macOS 26 (pitfalls we hit)

- The owner of every status item window is Control Center; the real owner must be matched through AX
  (`kAXExtrasMenuBarAttribute`) by midX (4 pt tolerance).
- `button.window.windowNumber` is **not** the CG window ID, and converting it crashes; Frost locates its own control
  items by frame (converted to CG coordinates) or by window title (the autosave name).
- `NSStatusBar.system.thickness` returns 22, which does not match the actual menu bar height (39 on notched
  displays); use `screen.frame.maxY - screen.visibleFrame.maxY`.
- A separator with `length = 10_000` is clamped to a 5016 pt wide window, which is enough to push the items on its
  left off screen; `length = 0` still leaves 16 pt of blank space (narrowed to 1 pt with a constraint trick).
- Windows off screen (pushed out, under the notch) cannot be captured (ScreenCaptureKit −3811), so only items with
  `isOnScreen` are captured and cached (memory + disk `~/Library/Caches/dev.frost.Frost/items/`). While the Frost
  Bar is open, a "live refresh" runs once per second (`LiveRefreshPolicy`: cadence and pause rules). The temporary
  expansion must happen under a freeze frame (`MenuBarFreezeFrame`, layer 26, click-through, covering only the area
  **left** of Frost's item); if the freeze frame fails, don't expand, and remove the freeze frame only after the
  collapse is **confirmed** — a user seeing the menu bar expand and collapse is a bug. The freeze-frame capture must
  **include** Frost's own windows: the Frost Bar panel's shadow reaches into the menu bar, and excluding it makes the
  strip of menu bar above the panel flash once per second; start the first round only after the panel's appearance
  animation finishes. The freeze-frame capture must also set `SCScreenshotConfiguration.ignoreShadows = false`: by
  default it **ignores window shadows**, and since the macOS 26 menu bar is transparent, the shadow of a window right
  below it (a maximized browser, etc.) darkens the menu bar's bottom edge, so a freeze frame without that shadow
  brightens once per second (measured on a real Mac; it can't be reproduced in the VM because windows there don't
  touch the menu bar — when verifying, place a window directly below the menu bar). The top edge of the Frost Bar
  panel window sits exactly at the menu bar's bottom edge (`FrostBarMetrics.topInset`), so the panel shadow is not
  drawn into the menu bar. Each round holds `ItemMover.transaction` from showing the freeze frame until it is removed;
  click forwarding waits for that. The freeze frame's screenshot is taken before the transaction, so a click during it
  doesn't wait (the round then gives up if a transaction ran meanwhile: the screenshot would be stale).
  Never put any Frost window at layer 25: the scanner treats layer-25 windows on the menu bar row as status items.
- Capturing several status items at once: an `SCContentFilter(display:including:)` containing only those items'
  windows + `backgroundColor = .clear` yields crops that are pixel-identical (alpha included) to per-window
  captures; an `excludingApplications` filter captures the opaque menu bar background and breaks glyph
  classification. Check the frames before and after capturing (when a text item gets wider, the items on its left
  shift).
- While an item is changing width, the system occasionally takes about 0.5 s to apply a change of the separator
  length: the stability check must require "already different from before the change" and must never treat
  "unchanged" after a timeout as stable.
- `NSPanel.isFloatingPanel = true` resets `level` to `.floating`: the Frost Bar panel actually sits at layer 3.
- Items that don't fit under the notch have `isOnScreen == false`, and their x does not reflect the real order;
  moves involving them must happen in the collapsed state (`whileCollapsedForMove`).
- AXPress blocks when it opens an NSMenu and returns `.cannotComplete`, but the menu is in fact open — don't add a
  click on top. `com.apple.*` items are always clicked directly with HID CGEvents.
- After a ⌘-drag the dragged item may get stuck in the "pressed" state; post an extra mouse-up before clicking.
- A ⌘-drag's mouse-down lifts the item to the cursor and the menu bar slides the windows between its old slot and the
  mouse-down (the Frost icon) over to close the gap; the mouse-up is placed against those *current* positions. A
  mouse-up posted at a fixed delay with frames read before the drag is either ignored (before the lift) or lands one
  slot off (target among the sliding windows). `ItemMover` releases via `DragRelease` (`spike-findings.md`, "Later
  measurement"). After the mouse-up the item jumps into its slot without sliding; only the windows left of it slide
  (~0.4 s). The Frost Bar clicks as soon as the item has landed (`ItemMover.move(_:to:until: .itemLanded)`,
  `LandingDetector`): its menu still opens at the final position. Click-to-menu latency is measured with
  `scripts/vm/guest-click-latency.swift` and the per-forward `click forward of …` log line.
- Views inside `.glassEffect` don't receive SwiftUI drops (put drop targets outside the glass layer).
- Cooperative activation (macOS 14+): a forwarded click doesn't count as user intent, so the target app's polite
  `activate()` is refused, and transient popovers therefore don't close on outside clicks. After detecting a
  non-menu popup, Frost hands activation over with `NSApp.yieldActivation(to:)`, with a "click outside" fallback:
  when the target app is not frontmost, Esc does nothing (the popover isn't key), so after a grace period Frost
  simply clicks the item again; only when it is frontmost does Frost send Esc first.
- Multiple displays: every status item has one window on each display's menu bar. The **real window**
  (`button.window`, whose title is the autosave name and which AX describes) is on the display with the **active
  menu bar**; clicking / focusing another display swaps its position with the replica's (the window ID stays the
  same). So the managed menu bar is `scanner.menuBarDisplay`; never decide with `CGMainDisplayID()` (scanning, the
  capture strip and the notch check all go by it). A replica = the real window shifted by a fixed per-display
  offset, with the same width; the only exception is Frost's separator narrowed to 1 pt (the replica stays 16 pt).
  On two displays of the same height, pushed-out real windows and replicas interleave, all outside the display
  rectangles, and geometry alone can't tell them apart (`MenuBarDisplayResolver`; measurements in
  `spike-findings.md`, "Multiple displays"). When the snowflake replica on an inactive display is clicked, the
  mouse-down / mouse-up first show up in Frost's **global** monitor (they belong to another window), and after
  switching displays the system does **not always** redeliver the click to the button (on a real Mac both left and
  right clicks can be lost; in the VM left clicks are redelivered, right clicks are not): `ReplicaClickDetector`
  recognizes and replays them, deduplicated by event timestamp. In the VM, `FROST_TEST_DROP_REPLICA_CLICKS=1`
  simulates lost left clicks too.
- Launches and quits of menu-bar-only apps (LSUIElement) don't trigger `NSWorkspace` launch/terminate
  notifications; observe the list of running apps instead.
- When verifying the freeze frame / anything that "lays a screenshot over the screen", **don't use only a black
  wallpaper**: shadows and color shifts are invisible on black. Use a colorful gradient wallpaper + a wide-gamut
  display profile (`scripts/vm/set-display-profile.swift`, see `docs/testing-vm.md`, "Verification techniques"),
  and trust the **VNC framebuffer**: comparing ScreenCaptureKit captures with each other can't reveal differences
  in the compositor (the freeze frame and the real menu bar are pixel-identical in SCK, while in the framebuffer
  they still differ by ≤ 2 levels on gradients, a known rounding difference).
- Don't grab the VNC framebuffer while doing timing or frame-by-frame checks in the VM: it slows the guest down
  (the clock skips seconds, refreshes show 0.5–0.8 s outliers). `screencapture -v` only emits frames when the image
  changes, so it can't tell whether a clock is on time (use a probe that captures the clock window).
- Every build runs with the Hardened Runtime. Builds signed with the self-signed certificate need
  `com.apple.security.cs.disable-library-validation` (`Frost-SelfSigned.entitlements`): it has no Team ID, so library
  validation would reject Sparkle.framework and Frost would not launch; Developer ID releases use `Frost.entitlements`
  without it. The VM runs with SIP disabled and does **not** enforce library validation, so it can't catch this
  (`docs/releasing.md`, "Hardened Runtime and entitlements").
- Don't put continuously running animations (e.g. `.symbolEffect(.breathe)`) in Frost's windows; one once froze the
  main thread. Use one-shot effects only.

## Code conventions

- Pure logic goes into FrostCore, tests first (TDD); keep the system-call parts thin.
- Log with `FrostLog.<category>` (`os.Logger`, subsystem `dev.frost.Frost`), not `NSLog` (on a real Mac Frost is
  launched by launchd with stderr = `/dev/null`, so `NSLog` output is lost). To view:
  `/usr/bin/log show --last 10m --info --style compact --predicate 'subsystem == "dev.frost.Frost"'` (in the VM:
  `make vm-logs`). In zsh `log` is a builtin, so a bare `log show` fails silently; always use `/usr/bin/log`. Use
  `privacy: .public` for window IDs, timings, bundle IDs and errors; use `.private` for values that may be user
  content, such as menu bar item titles / AX descriptions.
- FrostCore public types need `public` + an explicit `public init`; mark value types `Sendable`. UI/state classes
  use `@MainActor @Observable`.
- Coordinates: CG / AX / CGEvent always use the global top-left origin; convert to AppKit's bottom-left origin only
  when placing an NSWindow (and from it for NSEvent locations); convert with `ScreenCoordinates`.
- Test hooks (`FROST_TEST_*` environment variables and the like) are read only under `#if DEBUG` and listed in
  `docs/testing-vm.md`, "Debug-only test hooks".
- Every move (including the Frost Bar's whole "move out → click → move back" flow) must be wrapped in
  `ItemMover.transaction`.
- Language: code, comments, docs, test data and commit messages are in English. Chinese appears only in
  localization files (`*.xcstrings`); there is no Chinese anywhere else in the repository. The UI is written in
  English, and every user-facing string must be localizable (e.g. a SwiftUI string literal or
  `String(localized:)`, never a string built at runtime that bypasses the catalog), with its zh-Hans translation
  added to `Frost/Resources/Localizable.xcstrings` in the same change.
- Commit messages follow Conventional Commits (`feat:` / `fix:` / `docs:` / `test:` / `chore:`).
- The UI aims for a modern, restrained, native macOS 26 style (Liquid Glass, SF Symbols); check both Light and Dark
  Mode.
