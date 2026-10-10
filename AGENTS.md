# AGENTS.md

Instructions for AI coding agents working in this repository. User documentation is in `README.md`.

## Project

Frost: a macOS menu bar manager (similar to [Ice](https://github.com/jordanbaird/Ice)) that hides menu bar items and
shows the hidden ones in a glass panel below the menu bar (the Frost Bar).

- Supports **macOS 26** (Liquid Glass) and **macOS 27**, on two backends behind the same UI
  (`MenuBarBackend`: `.windowList` on 26, `.accessibility` on 27). No compatibility with older systems, and later
  versions run in a notice-only mode until they are measured (see "Key facts", supported OS gate).
- Stack: Swift 6.4 (Swift 6 language mode, `SWIFT_STRICT_CONCURRENCY: complete`), Xcode 27, SwiftUI + AppKit,
  XcodeGen, Sparkle 2 (SPM, automatic updates).
- Not sandboxed, distributed directly. Basic hiding and showing needs no permissions; the Frost Bar, the layout editor
  and every move need only Accessibility (`PermissionCapabilities`); Screen Recording is optional and only adds real
  icon images (captures, the disk cache, live refresh). Never gate a feature on "all permissions granted".

## Common commands

```bash
./scripts/create-signing-cert.sh   # once: create the local signing identity "Frost Local Signing"
make test-core                     # FrostCore unit tests (Swift Testing)
make build                         # xcodegen generates the project + xcodebuild (Debug, arm64)
make ci-build                      # unsigned universal Release build, the same command CI runs
make lint                          # Swift source lint checks of CI's Lint job (lazy sequence chains)
make vm-deploy && make vm-run      # deploy and run in the test VM (see below)
make vm-upgrade-test               # previous release's real data, then this build over it (VM); required for releases
scripts/release/release.sh 0.2.0   # package a release locally (DMG + appcast) without publishing; see docs/releasing.md
```

`Frost.xcodeproj` is generated from `project.yml` and is gitignored: change project settings in `project.yml`. The one
exception is the SwiftPM pin file `Frost.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`, which
XcodeGen preserves and which is committed (Sparkle is pinned with `exactVersion`; `make ci-build` and releases only use
the committed pins). When changing a package version, commit the updated `Package.resolved` from `make build`.

Before finishing any change, `make test-core` and `make build` must both pass without new warnings, and so must
`make lint`.

## Layout

- `Packages/FrostCore/`: logic and system adapter layer; all testable pure logic goes here (Swift Testing,
  `import Testing`, not XCTest).
  - `Model/`: `MenuBarItem`, sections and section state, screen geometry (`NSScreen.displayID`, `ScreenCoordinates`)
  - `Scanning/`: merges CGWindowList (layer 25) + Accessibility into `MenuBarItem`; multi-display resolution
  - `Layout/`: section classification, drop indices, layout reconciliation, panel positioning, placement of new items,
    the persisted item memory (`ItemMemoryStore`: seen icons, remembered sections, identity migration)
  - `Moving/`: ⌘-drag moves (`ItemMover`), click forwarding (`ItemClicker`), restore plans, activation handoff
  - `Capture/`: ScreenCaptureKit captures, glyph brightness, the disk cache, live refresh policy
  - `Permissions/`
- `Frost/`: app layer. `Sections/SectionController` (the three status items and the section state machine),
  `FrostBar/` (`FrostBarController` is split into panel, `+LiveRefresh`, `+Forwarding` and `+ObscuredCapture` files),
  `Settings/` (including the layout editor), `Onboarding/`, `Support/` (preferences, `EventMonitors`, the Debug-only
  `FrameProbe`), `App/` (`AppModel` wires the components and navigation callbacks together).
  `Resources/Localizable.xcstrings`: the String Catalog (English base, zh-Hans).
- `Tools/FakeItems/`: a fake third-party menu bar app for testing (VM testing only).
- `scripts/vm/`: VM testing scripts. `scripts/release/`: release scripts (`config.sh` is the single release
  configuration). `scripts/lint/`: lint checks run by CI and `make lint`. `Spikes/`: early proof-of-concept
  programs, not part of the build.
- `docs/macos-behavior.md`: measured macOS 26 menu bar behavior, and how macOS 27 differs (read it before changing
  low-level code).
- `docs/manual-test-checklist.md` (including "Known limitations"), `docs/testing-vm.md` (including "Verification
  techniques"), `docs/releasing.md` (releases, signing and keys), `docs/ux-journeys.md` (end-to-end user journeys,
  walked from a clean state).

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
3. **Safety constraints for synthesized events**: on macOS 26, when moving items, the mouse-down must physically land
   on the center of Frost's own item and is routed to the target item by window ID through event field `0x33`. Never
   post a ⌘ mouse-down at the position of a third-party item. Hide the pointer while synthesized events move it
   (`CursorConcealment`) and restore its position afterwards; the one exception is the Frost Bar's move out for a
   forwarded click, which leaves the pointer on the moved item (`CursorDisposition.onMovedItem`).
   **macOS 27 has neither per-item windows nor `0x33` routing**, so a move is a ⌘-drag that starts on the item itself
   (`ItemMover.Mechanism.directOnTarget`) — the one case where Frost posts a ⌘ mouse-down on another app's status
   item. It is allowed only under all of: a move the user asked for (a layout-editor drop, a Frost Bar click, or
   placing Frost's own items), inside `ItemMover.transaction`, after waiting for the user's physical buttons to be
   released (`UserMouseButtons`), at a position from an Accessibility read whose item identity and current geometry
   were verified, with the pointer concealed and restored, and with success claimed only from the order the bar
   reports afterwards — never from a delay. Nothing about the macOS 26 path is relaxed by this.
4. Do not call `NSStatusBar.removeStatusItem` on quit: it deletes the item's saved Preferred Position.
5. **Never commit private keys or certificates** (the Sparkle EdDSA private key, the .p12 of "Frost Local
   Signing"). Do not casually change the release signing identity or `SUPublicEDKey`; see `docs/releasing.md` for
   why.
6. Docs, comments and test data must not contain personal environment details (real app names, host names,
   accounts, absolute paths, etc.); use neutral descriptions ("a third-party menu app"). Commits to the public
   repository use the GitHub noreply address as author (`COMMIT_AUTHOR_*` in `scripts/release/config.sh`).

## Key facts (pitfalls we hit)

The bullets below are macOS 26 unless they say otherwise; macOS 27 is a separate block at the end of this section.

- **Supported OS gate**: the bullets in this list hold on macOS 26 unless a bullet says otherwise; macOS 27 needs the
  second backend (`MenuBarBackend.accessibility`) described under "macOS 27" below. `PlatformSupport.backend` decides
  once at launch from the major version (26 → `.windowList`, 27 → `.accessibility`, anything else → `.noticeOnly`;
  later versions stay unsupported until measured), and `RunningOS` is what the app layer reads. `.noticeOnly` creates
  only the snowflake (`SectionController.installNoticeOnly`): no separators (never removed either, so their saved
  positions stay), no scanner, Frost Bar, new-item placement, captures, freeze frames or layout editing, and no
  onboarding; the snowflake's menu and Settings show the notice, and Sparkle keeps working so a supporting release can
  arrive. Anything new that touches the menu bar must stay behind this gate. Test it on macOS 26 with
  `FROST_TEST_UNSUPPORTED_OS=1`, and on macOS 27 in the `frost-test-27` VM (`testing-vm.md`, "macOS 27 VM").
- The owner of every status item window is Control Center; the real owner must be matched through AX
  (`kAXExtrasMenuBarAttribute`) by midX (4 pt tolerance).

- `button.window.windowNumber` is **not** the CG window ID, and converting it crashes; Frost locates its own control
  items by frame (converted to CG coordinates), with the window title (the autosave name) only as a fallback.
- Without Screen Recording, `kCGWindowName` (window titles) is empty for other apps' windows (also through private
  window-property calls) and their windows can't be captured. Item identities therefore come from AX attributes
  (`ItemIdentityKey`: AX identifier, else description / help, else the index among the app's extras, which is creation
  order), never from titles; titles are only an extra signal for migrating title-keyed data (`IdentityMigration`).
  Numbers in descriptions / help texts are replaced with `<n>` before keying: some apps put live readings there (a
  fan-control app's tooltip shows its fan speeds), and a key that changes on every AX read re-keyed the remembered
  section every 20-30 s. Texts that differ only in numbers share a key and get occurrence suffixes (creation order);
  keys stored with numbers map to the new ones (`MenuBarItem.numberedIdentityKey`, `numberNormalizedEncoding`).
  `didChangeScreenParametersNotification` also fires when only the Dock changes size; compare `DisplayConfiguration`
  before rescanning or closing anything. An app hiding and showing its item (`isVisible`, e.g. an icon blinking for
  unread messages) gets a **new window** at the far left (Always Hidden) with no launch/quit event; the scanner's
  window watch (`MenuBarItemScanner.windowWatchInterval`, 3 s) notices it so the section memory can put it back.
  Control Center's clock and Control Center button are recognized by their AX identifiers
  (`com.apple.menuextra.clock` / `.controlcenter`), see `SystemItemRules`.
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
  moves involving them must happen in the collapsed state (`whileCollapsedForMove`). Some even lie left of the display
  like pushed-out items. They are captured in the background by moving them right of the Frost icon one at a time
  (`FrostBarController+ObscuredCapture`, `ObscuredCapturePolicy`) under a whole-menu-bar freeze frame at level 501: a
  ⌘-drag draws the lifted item over the Frost icon in layer-500 drag windows, which show through a layer-26 freeze
  frame. The freeze frame stays up until the item is back (a held mouse button delays the move back; the overlay's
  safety net is extended meanwhile, `ObscuredCapturePolicy.RestoreStep`), and the item's return is persisted before it
  is moved out, so quitting mid-wait leaves it for the next launch (`SectionKeeper.pendingReturns`), with the
  identities of its neighbours (`PendingReturn`, same key and 0.3.2's format plus optional `right` / `left`), so it
  goes back into its exact slot, or to the section's edge when they are gone.
- AXPress blocks when it opens an NSMenu and returns `.cannotComplete`, but the menu is in fact open — don't add a
  click on top. `com.apple.*` items are always clicked directly with HID CGEvents.
- After a ⌘-drag the dragged item may get stuck in the "pressed" state; post an extra mouse-up before clicking.
- A ⌘-drag's mouse-down lifts the item to the cursor and the menu bar slides the windows between its old slot and the
  mouse-down (the Frost icon) over to close the gap; the mouse-up is placed against those *current* positions. A
  mouse-up posted at a fixed delay with frames read before the drag is either ignored (before the lift) or lands one
  slot off (target among the sliding windows). `ItemMover` releases via `DragRelease` (`macos-behavior.md`, "Later
  measurement"). After the mouse-up the item jumps into its slot without sliding; only the windows left of it slide
  (~0.4 s). The Frost Bar clicks as soon as the item has landed (`ItemMover.move(_:to:until: .itemLanded)`,
  `LandingDetector`): its menu still opens at the final position. Click-to-menu latency is measured with
  `scripts/vm/guest-click-latency.swift` and the per-forward `click forward of …` log line.
- The user's own mouse during a ⌘-drag: `ItemMover` posts nothing if a button is down right before the mouse-down,
  posts the mouse-up early when one goes down meanwhile (also a click between two polls, seen by the HID press count,
  `UserMouseButtons.pressCount`; Frost's session-tap events don't count) and retries such an attempt without using up
  `maxAttempts` (`MoveAttempts`). A ⌘-drag posted while a menu is open doesn't take effect and closes the menu
  (measured: a menu the user opened right before a Frost Bar move back closed ~0.4 s later): moves that can wait pass
  `yieldingToMenus` (never under a freeze frame, which covers menus). After a fallback to the section's edge, the Frost
  Bar makes one corrective move into the slot (`RestorePlan.correction`). Time a click against a move back with
  `scripts/vm/guest-moveback-click.swift`.
- `@Observable` notifies on every assignment, equal or not: the scanner publishes `items` / `status` only when they
  change, and the layout editor's `state` reads only what it shows (each notification re-renders the whole editor, a
  30–70 ms hitch in the VM).
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
  `macos-behavior.md`, "Multiple displays"). When the snowflake replica on an inactive display is clicked, the
  mouse-down / mouse-up first show up in Frost's **global** monitor (they belong to another window), and after
  switching displays the system does **not always** redeliver the click to the button (on a real Mac both left and
  right clicks can be lost; in the VM left clicks are redelivered, right clicks are not): `ReplicaClickDetector`
  recognizes and replays them, deduplicated by event timestamp. In the VM, `FROST_TEST_DROP_REPLICA_CLICKS=1`
  simulates lost left clicks too.
- Permission requests (`PermissionsService`, `PermissionRequest`): showing the system prompt and opening the Settings
  pane together leaves the prompt behind System Settings, where it resurfaces after the grant, so never both.
  Accessibility (`AXIsProcessTrustedWithOptions` + prompt) prompts on every call, also when Frost is listed and denied:
  it is the whole request. Screen Recording (`CGRequestScreenCaptureAccess`) prompts only for a process's first
  request and only while TCC has no entry, and is silent otherwise: Frost waits up to 2 s for the prompt window (owner
  `universalAccessAuthWarn`) and opens the pane only when none appeared, in which case Frost is already listed. So the
  pane never opens without Frost in it (measured in the VM: fresh TCC, TCC reset, denied row, new process). A forwarded item (`ForwardLinger`) stays out only while its presentation is open or
  the pointer is on it (frame plus a margin), and returns 0.75 s after neither holds: while it sits right of the Frost
  icon the icon is one item further left than where users click.
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

### On macOS 27 (the accessibility backend)

- **There are no per-item windows.** `MenuBarAgent` draws the whole bar, so `CGWindowList` and per-window
  ScreenCaptureKit find nothing: item identities and geometry come from `kAXExtrasMenuBarAttribute`
  (`AXMenuBarInventory`). Each item is addressed by a window ID synthesized from its AX identity, which is what keeps
  the sections, the layout editor, the Frost Bar and the captures working on the same `MenuBarItem` values as on 26.
- **Use paired dividers at the arranged boundaries.** Each boundary has two bounded status items, created narrow
  (8 pt) and aligned while revealed. `BoundedDivider` caps each at 600 pt; a single oversized separator is ignored.
  After a layout drop, realign the pairs before collapsing. Empty sections do not consume collapse space.
- **Which icons the bar draws cannot be read reliably.** An overflowed icon can keep an old frame, and Apple's
  `NSStatusItem` `occlusionState` no longer reports visibility (FB23349447). Sections therefore come from the user's
  arrangement (`ItemMemoryStore`); unknown icons count as Visible. Retain the last revealed order for the collapsed
  Frost Bar instead of sorting stale frames. A positive exact AX hit establishes presence; a negative hit does not
  establish absence. Verify hiding against the VM framebuffer, never widths, counts or a fixed delay alone.
- **Own-divider placement needs narrow, consistent geometry and a positive Frost hit.** The macOS 26 constraint
  trick makes an own divider's AppKit and AX frames disagree on 27. Keep it 8 pt wide, including resize callbacks,
  and require `dragOwnItem` to hit Frost at its current centre before any down. An older collapsed-divider test hit
  a neighbour: that remains a rejection, not permission to drag at stale coordinates.
- **A Frost Bar click uses move-out / click / linger / exact return.** Reveal to reacquire the target and original
  neighbours, persist its pending return, move it right of the snowflake, then collapse the other items before a
  positively hit-tested plain HID click. Leave the pointer on the moved icon; return only after its presentation
  closes and the pointer leaves. Reveal again for the return and clear the record only after observing the slot.
  On 27 the snowflake action also reads currently held modifiers: the redelivered event can lose Option.
  Failed returns retain the record; launch recovery resolves its unique identities before retrying. This uses the
  existing UserDefaults format and does not promise power-loss durability. Primary clicks only are qualified.
- **Frost's own items are identified by the names they were created with** (`Frost27.HiddenDivider`,
  `Frost27.AlwaysHiddenDivider` and their `.Pair` companions), not through `FrostControlLocator`: on 27
  a divider held as a thin line reports an Accessibility frame that differs from its window's. When this broke, a layout drop silently did nothing, because
  `drop` returns early without `controlWindows`.
- **A drop into an empty band is resolved against one of Frost's own dividers**, an invisible 8 pt line while editing;
  the move is verified by the order the bar reports, with "the icon is on the divider's hidden side" as the check
  (`ItemMover.isSatisfiedOn27`) — requiring it to be immediately beside the line is stricter than the bar can express.
- **27 uses its own autosave names** so no saved macOS 26 separator position is inherited, and it never writes the 26
  `NSStatusItem Preferred Position` seeds (they place nothing there).
- **Captures on 27 come from the menu bar strip, not from windows.** Nothing can be addressed per item: there are no
  status item windows, and `MenuBarAgent`'s own window is not shareable (`SCShareableContent` lists none of its
  windows — measured). So the strip is captured once from the display (`SCContentFilter(display:excludingWindows: [])`
  with `sourceRect` on the bar row) and each item's glyph is lifted out of it (`StripGlyphExtraction`: the bar is a
  blurred material, so the background under a crop is nearly flat — measured at most one level per channel — and is
  subtracted per column). A crop that is background only means the bar doesn't draw that item at the frame
  Accessibility reports, so it gets **no** image and keeps its app icon rather than showing a neighbour's; that also
  covers items pushed out of the bar. The purple recording indicator shows while capturing, as on 26.
  `docs/macos-behavior.md`, "macOS 27" has the measurements.

## Code conventions

- **Walk the user journeys, not just the features**: after changing a user-facing flow (permissions, onboarding,
  Settings, the Frost Bar, the snowflake menu, updates), walk the affected journeys in `docs/ux-journeys.md` in the VM
  from a clean state, granting permissions through the real System Settings switches. Look for friction (extra
  clicks, lost windows, lingering prompts, stale state, dead ends), not only failures. New flows get a journey.
- **Keep the README in step with the UI**: after changing how a window looks or what it shows (Settings, the Frost
  Bar, onboarding, the snowflake menu), check `README.md`: the screenshots in `docs/images/` (retake them in the VM:
  Light Mode, a colorful wallpaper, the window only, neutral test item names), the wording that names tabs, buttons
  or flows (e.g. "Settings → About", what Grant Access does), and the Features / Permissions / Updates sections.
  Update them in the same change.

- Pure logic goes into FrostCore, tests first (TDD); keep the system-call parts thin.
- **Migrations of persisted data are tested through the real launch path with previous-release data**: anything an
  earlier release stored (UserDefaults keys and formats, the image disk cache) gets a test that seeds real storage (a
  `UserDefaults` suite, a temporary cache directory) exactly as that release wrote it (take the keys and format from
  that release's tag, `git show v<x.y.z>:<path>`), drives the code that runs at launch over several items at once
  (some with data in each earlier format, some with none, some ambiguous), and checks that a second launch changes
  nothing (`ItemImageCacheUpgradeTests`, `ItemMemoryUpgradeTests`). Tests of the individual helpers are not enough:
  0.3.1 crashed at launch in the composition of two separately tested helpers. Launch-time logic in the app layer
  moves to FrostCore so it can be tested this way (`ItemMemoryStore`).
- **No lazy sequence chains with closures**: `.lazy` followed by `map` / `compactMap` / `filter` / `flatMap` runs its
  closures each time an element is accessed, so a closure may run more than once for one element (`first` on a lazy
  `compactMap` runs it twice for the element it returns); with side effects that is a bug (the 0.3.1 crash). Use a
  loop, an eager chain or a closure-free lazy view (`joined()`). `scripts/lint/lazy-chains.sh` (CI, `make lint`)
  enforces it; a deliberate lazy chain with pure closures carries `// lint: lazy-ok (<reason>)` on its `.lazy` line.
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
