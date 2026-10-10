# Frost manual test checklist

Go through every item before a release. All GUI testing happens in the VM (see [`testing-vm.md`](testing-vm.md)); never
run Frost on the development machine's desktop. Items the VM cannot simulate (a notched display, a real external
display, etc.) are tested on a dedicated test Mac (the second display in the VM is a virtual display inside the guest;
see `testing-vm.md`).

For each item, record: environment (model / displays / macOS version) and result (✅ / ❌ / notes).

> **Do not move the developer's own third-party items** for destructive experiments. When you need movable test items,
> install a few common menu bar apps in the test environment (e.g. Rectangle, Stats, AltTab).

## 0. Preparation

- [ ] `./scripts/create-signing-cert.sh && make build` succeeds; `make test-core` passes.
- [ ] Reset the first-launch state: `defaults delete dev.frost.Frost` (clears preferences, `hasCompletedOnboarding` and
  the seeded `NSStatusItem Preferred Position` values).
- [ ] Remove Frost's Accessibility and Screen Recording grants in System Settings → Privacy & Security (or
  `tccutil reset Accessibility dev.frost.Frost`, `tccutil reset ScreenCapture dev.frost.Frost`). Removing a row with
  "−" asks for the admin password ("Modify Settings"); the running Frost keeps reporting the permission it had until
  it is relaunched (macOS decides ad hoc trust once per process), so relaunch it before checking what the app shows.
  Frost re-adds itself to the Accessibility list (switch off) as soon as it uses the AX API again after the relaunch.
- [ ] Logs: every "log `…`" below is checked in the unified log (Frost uses `os.Logger`, subsystem `dev.frost.Frost`;
  it no longer uses `NSLog`, because stderr is `/dev/null` when launchd starts it):
  `/usr/bin/log stream --info --style compact --predicate 'subsystem == "dev.frost.Frost"'`, or afterwards
  `/usr/bin/log show --last 10m --info …` (in zsh a bare `log` is a builtin). At least one line should appear after launch (e.g.
  `managing the menu bar of display …`).

## 1. First launch and permission onboarding

- [ ] First launch: the snowflake appears to the right of the third-party items and to the left of Control Center /
  the clock; all other third-party items are moved into the Hidden section.
- [ ] The onboarding window opens automatically, centered, with a transparent title bar and blurred background; the
  traffic lights don't cover content; text and cards are clear in both Light and Dark Mode. The permission
  descriptions read exactly like the About tab's (English and Simplified Chinese), and the prominent buttons have white
  text on the accent color.
- [ ] The onboarding window is exactly as tall as its content: the footer buttons are never cut off (also on macOS 27's
  taller fonts and in Simplified Chinese), and when a notice appears or goes (granting, the relaunch note) the window
  grows or shrinks with a short animation while its top edge stays put.
- [ ] Click the **Grant Access** button on the Accessibility card (first time, `defaults delete dev.frost.Frost` and no
  TCC row): only the system prompt appears, nothing opens behind it; its "Open System Settings" button opens Privacy &
  Security → Accessibility with Frost listed. Once the switch is on, no stray prompt remains, also after a relaunch.
  A second click shows the prompt again (Accessibility prompts on every call). After turning
  the switch on in System Settings, the card turns into a green checkmark within
  about 1 second (the checkmark bounces once), without switching back to Frost.
- [ ] The Accessibility card is tagged **Required** and the Screen Recording card **Optional**.
- [ ] Once Accessibility is granted (Screen Recording still missing): the "all set" message and the done / "open layout
  editor" buttons appear already; the Frost Bar and the layout editor work (see "Accessibility only" below).
- [ ] Click the **Grant Access** button on the Screen Recording card: only the system prompt when Frost has no
  Screen Recording entry yet (fresh TCC, `tccutil reset`, removed with "−": also after a relaunch); the pane opens
  directly (about 2 s later, Frost listed) only when the system stays silent (Frost already listed and denied, new
  process). Never both. While the system prompt is up the card shows a spinner (not "Needs Relaunch" underneath the
  prompt); once it closes the card shows "Needs Relaunch" instead of the button, a note below says Frost must be relaunched, and
  **Relaunch** is the prominent default button (Return) while "Open Layout Editor" is not shown. The description
  mentions the purple recording dot.
- [ ] Deny the system prompt (or close it): the note's **Open System Settings** link opens Privacy & Security →
  Screen & System Audio Recording with Frost listed — one click back to the pane, without relaunching first. The same
  link sits next to **Relaunch** on the About tab's Screen Recording row, in the layout editor's footer notice and in
  the Frost Bar's hint (there the sentence and the two actions stack, since they don't fit side by side in a panel
  that narrow). In English and Simplified Chinese, Light and Dark Mode, nothing truncates or overlaps.
- [ ] Click the relaunch button: Frost quits and relaunches within about 1 second, the onboarding window reappears,
  and Screen Recording shows as granted.
- [ ] Once Accessibility is granted: an "all set" message appears; the bottom buttons change to a done button plus an
  "open layout editor" button. The latter closes onboarding and opens the Settings window on the **Layout** tab (it
  also switches to Layout if the Settings window is already open on another tab).
- [ ] The later / done buttons, the close button and Esc (when not everything is granted) close onboarding; after
  that, relaunching Frost no longer opens onboarding automatically.
- [ ] After closing onboarding, revoke Accessibility in System Settings → open the **About** tab of the Settings
  window: within about 1 second the status changes to a "grant" button; clicking it shows the system permission
  prompt / Accessibility pane directly (no onboarding window). Granting flips the row to "Granted" within about 1
  second.
- [ ] Without Screen Recording, click the **About** tab's Screen Recording "grant" button: the Screen Recording pane
  opens and the row changes to a relaunch note with an "open system settings" link and a relaunch button. Turn Frost
  on, then either click the relaunch button or choose System Settings' "Quit & Reopen": Frost comes back with the
  Settings window open on **About**, Screen Recording granted. The same works from onboarding (onboarding reappears). An ordinary ⌘Q and a later launch
  (more than a minute later, or without a pending request) reopen no window.

## 2. Main menu and shortcuts (Frost has no visible menu bar menu)

- [ ] With the Settings or onboarding window key: ⌘W closes the window; ⌘Q quits Frost; ⌘, opens Settings; ⌘M
  minimizes the Settings window.
- [ ] In selectable text (the version number on the About tab), ⌘C copies and ⌘A selects all.
- [ ] **Hide Frost (⌘H)** with the Layout tab open: the Settings window hides, the menu bar leaves editing state and
  collapses. Reopen Settings (right-click the snowflake → "Settings…"): editing resumes once the window is key.
  Opening the Frost Bar while hidden shows Frost again (the Settings window comes back behind the front app; editing
  waits until it is key). Another app's "Hide Others" doesn't hide Frost (macOS leaves accessory apps alone).
- [ ] With the Frost Bar open, ⌘W closes the Frost Bar (same as Esc). **To be confirmed**: whether main menu shortcuts
  are delivered when the non-activating panel is key while Frost is not active.

## 3. Sections and show / hide (no permissions needed)

- [ ] Left-click the snowflake: the Hidden section expands / collapses (the snowflake itself doesn't animate); ⌥-click
  also expands the Always Hidden section.
- [ ] Auto-hide: after expanding, items hide again after the configured delay; with **Automatically hide** off they
  stay expanded.
- [ ] Clicking outside collapses immediately (In Menu Bar mode with **Automatically hide** on): clicking another app's
  window, **and also Frost's own Settings window** (Behavior tab), collapses immediately; clicking the menu bar (empty
  space, other items) does not, and clicking the snowflake toggles as usual.
- [ ] Right-click the snowflake: the menu contains "Settings…", "Check for Updates…" and "Quit Frost", each with an
  icon so the titles line up (also in Simplified Chinese).
- [ ] Without any permissions, the display mode is forced to In Menu Bar, and hiding / showing works normally.
- [ ] With Accessibility only (no Screen Recording), Automatic still uses the Frost Bar on a notched display.

## 4. Layout editor

- [ ] Open the **Layout** tab: the menu bar enters editing state (everything expanded, both divider lines visible);
  the three glass section bands show live images. Right after relaunching Frost, every tile (Visible section
  included) already shows its cached image when the tab appears: no "?" or blank placeholder tiles.
- [ ] Drag items between sections and reorder within a section: after the drop the item shows an in-progress state,
  and once the real menu bar has moved it the state matches; any failure shows the error toast (the tile never just
  jumps back without one, and never goes blank). The drag image disappears with AppKit's normal end-of-drag fade
  (~0.3 s) and the move starts only after it (it no longer hangs over the drop spot for up to a second).
- [ ] Drops land exactly where they were dropped on the first try (no error toast, the tile never ends up one slot off),
  in particular: an item dragged **rightwards** within Hidden or within Always Hidden, an item dragged from Always Hidden
  into the middle or end of Hidden, and a Visible item dragged **leftwards** past another Visible item. These are the
  moves whose target slides while the menu bar lifts the item (`DragRelease`); they take about half a second longer
  than other moves.
- [ ] VoiceOver: each editor tile is an image labelled "App name — item description" (its own description or title,
  when it has one), with its section and state ("Hidden, doesn't fit in the menu bar") as its value; Frost Bar tiles
  use the same label.
- [ ] While a move is in progress, quickly drag and drop another item: the second item immediately shows in its new
  position (in-progress state) and is queued, running automatically after the first move finishes; no "please wait"
  message appears, and both end up in the right place.
- [ ] The editor has no refresh button; content refreshes automatically: launch a new menu bar app while the editor is
  open, and within about 10 seconds its item appears with the correct owner (hover name) and image; switching to
  another app and back to the Settings window triggers one full refresh immediately.
- [ ] When the menu bar can't be read / Frost's separator can't be found: the placeholder says it is retrying
  automatically (progress is shown only briefly while a retry runs), it retries about every 3 seconds, and the editor
  appears automatically once it recovers.
- [ ] **Rapid drags**: drop an icon and start dragging the next one right away (within half a second), several times:
  a pending move waits until the mouse button is released (log `waiting for the mouse button to be released`, or the
  drop simply queues), no icon is ever carried along with your drag or dropped off the menu bar (no "Remove" badge),
  and the mouse button is not left pressed afterwards.
- [ ] Leaving the Layout tab or closing the Settings window: the menu bar leaves editing state and collapses (when
  switching tabs, only after the cross-fade has finished, so the fade doesn't stutter).
- [ ] **Covered or away**: with the Layout tab open, cover the Settings window completely (e.g. move it to another
  Space, or put a full-screen app over it): editing ends and the menu bar collapses; bring the window back and click
  into it: editing resumes. Lock the screen (⌃⌘Q) or let the displays sleep: editing ends and the editor's periodic
  refreshes stop (log `user away (screenLocked)` / `(displaysAsleep)`); after unlocking, editing resumes once the
  window is key (log `user back`).
- [ ] Revoke Accessibility: the editor shows an "Accessibility Required" placeholder that updates as permissions
  change and does **not** expand the menu bar; granting while the tab is visible starts the editor (menu bar expands
  once); its button requests Accessibility directly (no onboarding window). Settings reopens on the tab last used.
  A row with more tiles than fit shows edge fades and a paging arrow on the overflowing side; drops into any position
  still work (scroll first with the arrows or the trackpad). With Accessibility only, the footer's
  Screen Recording link requests it and then offers a relaunch (Frost comes back on the Layout tab). Revoking only Screen Recording does **not** show the placeholder
  (see "Accessibility only").
- [ ] **Known risk (b)**: when moving an item hidden under the notch, the menu bar briefly collapses and then
  restores. Confirm it doesn't flicker excessively, the layout is correct afterwards, and editing state is restored.
- [ ] Items hidden under the notch are shown with the app icon (or a previously cached image) instead of a capture.

## 5. Frost Bar

- [ ] Click the snowflake on a notched display (default) or with the mode set to Frost Bar: a rounded glass panel drops
  down from below the snowflake (top edge 6 pt below the menu bar, right edge aligned with the snowflake, clamped
  8 pt inward at the screen edge), sliding down a few points while fading in (no scaling), with no continuous
  animation; no hard edges from a clipped shadow around the panel (most visible over a white window).
- [ ] **First open after launch looks the same as later opens (user report: "after upgrading, the animation on the
  first click looks off")**: relaunch Frost (after an update or reinstall, with and without the image cache), wait a
  couple of seconds, then click the snowflake: the panel appears right away and plays the same smooth drop-down as on
  the second and third click, with no delay, stutter, flash or resize; nothing appears on screen at launch (the panel
  is prepared invisibly, log `warm-up: panel rendered off view`). VM method: Debug build with
  `FROST_TEST_FRAME_PROBE=1`; each open logs `frame-probe frostbar-open-<n>`: `frostbar-open-1` has the same
  `firstFrame` (~10–20 ms) as later opens and no hitch during the animation (`at=` entries below ~250 ms), see
  "Verification techniques" in `docs/testing-vm.md`.
- [ ] Items are laid out in a grid (at most about 5 regular items per row; wide text items take their own width and wrap
  naturally; rows are left-aligned); hover highlights an item and the name bar at the bottom shows the app name (the
  item count when nothing is hovered); hovering doesn't resize the panel; with more items than fit the screen height,
  the panel scrolls vertically.
- [ ] **Right click / ⌥-click on a tile** (VM: FakeItems' gear `FIDual` shows a different menu per button): right-click
  (or Control-click) the tile: the item's *secondary* menu opens at the item (FakeItems log `dual click right`);
  ⌥-click the tile: its primary menu with the extra "hidden option" entry (`dual click left option=true`); a plain
  click is unchanged. VoiceOver offers "Show menu" on a tile (forwards a right click). Log: `click forward (right)`.
- [ ] **The item lingers after its menu closes (user report: "after clicking a hidden icon via the Frost Bar, I can't
  right-click it in the menu bar")**: click a tile, then right-click the item in the menu bar: the item stays where it
  is and (on a second right click if the first one only closed the menu) its right-click menu opens there. With the
  pointer resting on the item it stays out (up to 5 s without a click, log `linger ... over (idle)`); picking a menu
  entry or moving the pointer off the item (a few points of margin; elsewhere on the menu bar doesn't count) moves it
  back to its original slot about 0.75 s later (`over (pointer left)`), so the snowflake is back where it was and
  clicking its usual spot opens the Frost Bar, not the forwarded item's menu.
  Reopening the Frost Bar moves it back at once (`ended early`); quitting during the linger restores it too (log
  `deferring termination`, then a ⌘-drag back to the original anchor; relaunch: the item is in its old section). It
  never moves while a mouse button is held.
- [ ] **The pointer moves once on a forward and never visibly on background moves (user report: "the pointer jumps
  to the menu bar and back")**: left-click, then right-click a tile: the pointer disappears briefly and reappears on
  the item in the menu bar, where it stays (it never shows over the snowflake, and never goes back to the tile); the
  item lingers while it rests there. Move the pointer away: about 0.75 s later the item moves back while the pointer
  stays where it is, with no flash over the menu bar (log `⌘-drag … pointer away N ms`, ~60–90 ms in the VM, hidden
  throughout). Same for layout editor drops and new-item placement. After every move, including quitting during a
  linger, the pointer is visible. VM evidence: `guest-cursor-probe.swift forward` with `screencapture -v -C`.
- [ ] **A click on the menu bar as the item moves back (known issue: "an item ended up in the wrong slot")**: forward
  a menu item from Hidden, close its menu with a click on the desktop and click the menu bar right as the item moves
  back, on empty space, on the snowflake, on the moved item's spot and on another item's menu (VM:
  `guest-moveback-click lift <id> <x> <y>` clicks the moment the move back lifts the item, `away … <delayMs>` sweeps
  the timing around 750–950 ms). The item always ends up in its exact slot (`guest-sections` before and after lists
  the same order). A menu the click opened stays open: the move back waits for it (log `waiting for the open menu to
  close before the next ⌘-drag`) and happens once it closes; before, the ⌘-drag closed it about 0.4 s after it opened
  and needed a second attempt. A ⌘-drag the click cut short that didn't take effect is retried without using up the
  retries (log `was cut short by the user's mouse button and didn't take effect`, then `attempt 2`); if the anchor
  move fails anyway and the item lands at its section's edge, one corrective move follows (log `is not back in its
  slot; moving it …`).
- [ ] **Snowflake click during a linger opens the Frost Bar in one click (user report: "after a right-click from the
  Frost Bar, clicking the snowflake again seems to do nothing")**: right-click (and, separately, left-click) the
  `FIDual` tile, close its menu with Esc (or leave it open), then click the snowflake once while the item still
  lingers: the item moves back and the Frost Bar appears right away, already under the snowflake's final position
  (the snowflake slides right by the item's width into place above it; log `Frost Bar opening: waiting for the click
  forward in progress`, `linger … ended early`, `Frost Bar presented N ms after the click`: in the VM about 150–250 ms
  with the menu already closed, about 400 ms when the click also closes the menu; it was 600–1000 ms before). A second click on the snowflake right after the first (before or just after the panel
  appears) keeps it open (log `Frost icon clicked while the Frost Bar is opening; keeping it open`); a click once the
  panel has been visible for a moment closes it as usual. Every close logs its reason (`Frost Bar closed (…); panel
  shown for N ms`). After a forwarded right click whose menu was closed, the first left click on an app menu (e.g.
  Finder's File) or another menu bar item works.
- [ ] ⌥-click the snowflake: a thin divider and an "Always Hidden" heading appear below the Hidden section, followed
  by the grid of Always Hidden items. While the panel is open, a plain click on the snowflake always closes it (one
  click, whatever it was opened with), and a ⌥-click shows / hides the Always Hidden section: the panel's height
  animates smoothly (about 0.25 s) while the section fades in after the footer has moved down, or fades out before the
  panel shrinks; the panel's top edge and the tiles above never move, in any frame (record and check frame by frame).
- [ ] **No one-frame jumps when the panel changes size** (user report: "the panel jumps"): with the panel open, quit
  and relaunch an app whose item is in the Hidden section, switch Light / Dark Mode, and toggle ⌥: in a high-rate
  recording the panel's top edge and right edge stay put in every frame (it grows and shrinks downward / leftward
  only).
- [ ] **No visible expansion in the menu bar (user report: "the hidden items expand, then disappear")**: delete the
  image cache (`rm -rf ~/Library/Caches/dev.frost.Frost/items`), relaunch Frost and click the snowflake: the menu bar
  always looks collapsed (hidden items never appear in it), and after about 0.3 s the app icons in the panel are
  replaced by real captures in place: each placeholder tile already has the item's width, so the panel neither resizes
  nor reflows when the captures arrive. The freeze frame covers only the menu bar **to the left of** the snowflake (the
  snowflake, clock and Control Center stay live). Check frame by frame in a screen recording (VM method: see
  "Verification techniques" in `docs/testing-vm.md`).
- [ ] **Live refresh**: put a changing item in the Hidden section (temperature / network speed / timer; in the VM,
  FakeItems' `FIClock`, whose title increments every second), open the Frost Bar and keep it open for 10 s: its tile
  updates once per second; other tiles don't jump. An item whose width keeps changing (in the VM, `vm-fake-items.sh
  launch A 0 net`) keeps the widest width seen while the panel is open (its tile never shrinks back): the panel
  resizes / reflows at most once per item and open, typically not at all after the first second, and never
  oscillates. No frame of the recording shows the menu bar left of the snowflake expanded, and the clock
  (with seconds shown) ticks every second as usual. When the panel closes, the log has a one-line summary
  `live refresh: N cycle(s) … overlay up … ms` (with `FROST_LIVE_REFRESH_TRACE=1`, one timing line per cycle).
- [ ] **Pause rules**: with the panel open, move the pointer onto the menu bar left of the snowflake, or hold the mouse
  button down inside the panel: log `live refresh paused: pointerInMenuBar` / `mouseDown`, and `resumed` after moving
  away / releasing. It also doesn't expand while a menu is open, a click forward or move is in progress, the layout is
  being edited, the menu bar is expanded in place, or permissions are missing (`LiveRefreshPolicy`).
- [ ] **No menu bar flicker (user report: "the menu bar keeps flickering after clicking the snowflake")**: with a
  colorful / gradient wallpaper (not black: nothing is visible on black), open the Frost Bar for 10 s and watch the
  menu bar above the panel and left of the snowflake: no once-per-second brightening / darkening, color shift or glyph
  jitter. VM method: see "Verification techniques" in `docs/testing-vm.md` (the VNC framebuffer is authoritative).
- [ ] **Click / close during a refresh**: click menu and popover items in the panel while a refresh is in progress:
  log `activation waits for the live refresh cycle to restore the collapsed state`, the menu / popover opens in the
  right place, and the item moves back after it closes; reopening the panel continues refreshing as usual. Press Esc
  during a refresh: the freeze frame is removed right away, the menu bar is collapsed, and no Frost windows are left
  behind (`panel closed during a live refresh cycle; it will collapse and clean up`).
- [ ] **Away**: with the panel open, lock the screen or let the displays sleep: the panel closes (log
  `user away: closing the Frost Bar`) and no live refresh rounds run while away; clicking the snowflake on the lock
  screen (if shown) doesn't open it; after unlocking it opens normally.
- [ ] **Click while another move runs**: launch a new menu bar app (its item lands in Always Hidden and Frost moves it
  to Hidden, see `vm-fake-items.sh`), and right away click an item in the Frost Bar: the click is forwarded once the
  placement finishes (log `activation waits for another move to finish`), not dropped.
- [ ] **New items while the panel is open**: launch an app that adds several new items (in the VM, forget some
  FakeItems extras and `vm-fake-items.sh launch A 6`) and open the Frost Bar while Frost places them: the panel stays
  open (Frost's own ⌘-drag events don't count as outside clicks), placement stops after the current item (log
  `stopped placing new items (the Frost Bar is open)`) and continues once the panel closes.
- [ ] **Cache first after relaunch**: with an image cache present, relaunch Frost and open the Frost Bar: the panel
  shows cached images as soon as it appears (log `loaded N item image(s) from the disk cache`, written about a second
  after launch, before the first click), then starts refreshing every second.
- [ ] **Items under the notch / that don't fit** (a crowded notched display; in the VM, `vm-fake-items.sh launch A 30`
  and open with ⌥ held so they don't fit even when expanded): items that don't fit show the app icon (or the cached
  image from the disk cache), and the rest refresh every second as usual (log `captured 17 of 40 item(s)`), at the
  same pace. If none of the panel's items fit, it stops expanding (`paused: nothingToCapture`) until the set / order of
  menu bar items or the display configuration changes, or the refresh button is clicked.
- [ ] **Background capture of items behind the notch** (same setup, image cache deleted:
  `rm -rf ~/Library/Caches/dev.frost.Frost/items`, then relaunch): open the Frost Bar once (log `N item(s) behind the
  notch`), close it, park the pointer on the desktop and wait: about every 3 s one of them is captured (log
  `background capture of item <id> (missing): captured, back in its exact slot; … total ~0.6–1.3 s`), never in the first
  20 s after launch. Reopen the Frost Bar: those tiles now show real images instead of app icons, also after a
  relaunch (disk cache). Record the menu bar meanwhile (VM: `screencapture -v -C`, compare every frame left of the
  system items with a frame at rest): no frame shows an item moving, the snowflake shifting, the lifted item's drag
  image or the pointer; the pointer stays where it was; `dump-status-windows` before and after lists the same order.
- [ ] **Background capture yields to the user**: it waits (log `background capture waits (<reason>)`, once per reason)
  while the Frost Bar or the layout editor is open, the menu bar is expanded, a menu is open, a mouse button is held,
  the pointer is over the menu bar, or the mouse / keyboard was used in the last second. During one: click the frozen
  snowflake — the item moves back at once (log `a click on the frozen menu bar`, `interrupted, back in its exact
  slot`) and the Frost Bar opens right after (`handling a Frost icon click taken by a background capture's freeze
  frame`); press and hold the mouse on the desktop — it moves back once the button is released; neither leaves an item
  in the Visible section. An interrupted item is retried about 10 s later; a failed one backs off (1, 2, 4… min).
- [ ] **Quitting with an item moved out puts it back into its exact slot on the next launch (known issue: "it went
  to the section's edge")**: with `FROST_TEST_OBSCURED_RESTORE_PAUSE_MS=8000`, wait for a background capture to move an
  item out (`guest-sections` lists it in Visible) and kill Frost (`pkill -9 -x Frost`); `pendingItemReturns.v1` holds
  the item with its neighbours (`"right"` / `"left"`). Relaunch: it goes back left of its old right neighbour (log
  `moved … back to hidden (leftOf(<id>)): Frost had moved it out before quitting`), the order is the one before the
  move out, and the entry is gone. With its neighbours' apps quit meanwhile it goes to the section's edge; a pending
  return written by 0.3.2 (no neighbours) also goes to the edge.
- [ ] **CPU**: with the panel open for 30 s, Frost's average CPU is well below 15% (about 3–5% measured in the VM); back
  to 0 after closing.
- [ ] The image cache stays fresh: after expanding the Hidden section in In Menu Bar mode, opening the layout editor,
  or clicking an item through the Frost Bar, the corresponding cache file
  (`~/Library/Caches/dev.frost.Frost/items/*.png`) is updated.
- [ ] **Contrast (the user-reported case)**: dark menu bar (dark wallpaper or Dark Mode, capturing white glyphs) with
  a white window (TextEdit) right below the panel: when the glass gets lighter, monochrome glyphs turn dark and stay
  legible; check a light menu bar / Dark Mode as well. Color icons are shown as-is; only color icons whose outline is
  pure white / pure black get a faint backing plate.
- [ ] Clicking outside the panel / Esc closes the panel.
- [ ] Clicking a tile doesn't make the snowflake show a pressed (dark) highlight while the item is moved out and back
  (the ⌘-drag's mouse-down lands on the snowflake; its highlight is suppressed during Frost's own moves).
- [ ] **Known risk (a), click forwarding**: click a hidden item → the item is temporarily moved to the Visible section
  → its menu / popover opens in the right place → after the menu closes, the item moves back to its section. **Verify
  with real third-party items** (the first synthesized click after a ⌘-drag move has been observed to be ignored), and
  test separately: a regular menu, a popover app, and an app that shows nothing when clicked (it should move back
  after about 1 second).
- [ ] **Click latency**: a hidden item's menu / popover appears about 0.15–0.2 s after clicking its tile (log
  `click forward of <id>: … click <ms>`), already at the item's final position right of the snowflake (not sliding in
  after it), also when the panel was opened just before the click; repeated quick clicks on tiles never leave an item
  stranded in the Visible section.
- [ ] With a menu kept open for a long time (including over 60 seconds), the item is not moved away; after clicking
  elsewhere to close the menu, the item moves back.
- [ ] Popover items: move back after the popover closes; if the popover never closes, they are forced back after
  60 seconds.
- [ ] **Outside-click fallback waits for the user**: forward a popover whose app only uses cooperative activation (in
  the VM, the cooperative fake item) with the Settings window open, then press the mouse on the desktop and keep it
  held (drag-select): no Esc and no toggle click while it is held (log `deferring the outside-click fallback`); the
  popover closes right after release. Then forward it again and close it by opening another app's menu bar menu:
  that menu stays open (it is not closed by the toggle click); the popover closes after that menu closes.
- [ ] **Popover with cooperative activation** (the app only calls `NSApp.activate()`; in the VM,
  `scripts/vm/vm-fake-items.sh launch A 0 polite`): after opening it through the Frost Bar, the app becomes frontmost
  (activation hand-off: Frost activates itself on the Frost Bar click and, after detecting a non-menu popup, hands off
  to the app with `yieldActivation(to:)` + `activate(from:)`), and clicking outside closes the popover within about
  0.5 s and moves the item back. If the hand-off is skipped or fails, the fallback closes it: when the app is not
  frontmost, about 0.3–0.4 s after the outside click Frost **directly** clicks the item again (log
  `… its app is inactive; clicking the item to toggle it closed`, with no `sending Esc`); the popover disappears after
  about 0.9 s, the item moves back after about 1.1 s, and the popover is not reopened. When the app is frontmost (e.g.
  clicking the Dock after a successful hand-off), Frost first sends Esc after 1 s (`sending Esc`) and clicks the item
  again only if it still doesn't close.
- [ ] The activation hand-off doesn't steal focus: after forwarding a click to a menu item / an item with no action,
  the previously frontmost app becomes frontmost again (its window title bar returns to the active state); with
  Frost's Settings window open (and Frost not frontmost) there is no hand-off, and the Settings window is not brought
  to the front.
- [ ] Focus returns to the app that was frontmost before the Frost Bar opened: with the Settings window open and
  **Frost frontmost**, open a popover through the Frost Bar (handed off to its app), then click empty menu bar space to
  close it: Frost becomes frontmost again and the Settings window is still in front (log
  `Frost was frontmost before the hand-off … returning to Frost`), not behind another app. If you close it by clicking
  another app's window instead, that app becomes frontmost (log `user clicked another app … not returning to Frost`).
- [ ] No hand-off for menus: first forward an app's popover while the Settings window is open (the hand-off is
  skipped), then close Settings and forward its menu: the menu stays open, doesn't close by itself after about 0.25 s,
  and focus isn't taken by the app.
- [ ] Quit Frost while a menu is open (e.g. `osascript -e 'quit app "Frost"'`): quitting is deferred; the item moves
  back first, then Frost quits.
- [ ] Empty states: with no hidden items, the panel says there are no hidden items and offers a button to arrange
  items; with missing permissions, it says permissions are needed and offers to open onboarding; when the menu bar
  can't be read, it says the menu bar items can't be read and offers a refresh button (each is a centered badge +
  title + description + button inside the panel).
- [ ] **Known risk (d)**: how Liquid Glass rendering, the appear / disappear animation and hover effects look on a real
  desktop (offscreen rendering cannot verify the glass effect).

## 6. Settings window appearance

- [ ] **Known risk (d)**: how the transparent title bar, the toolbar tabs (Layout / Behavior / About, the selected one
  highlighted), the grouped Behavior and About forms, the glass bands of the layout editor and button hover / press
  effects look in Light and Dark Mode and on different wallpapers. The window background is the standard opaque one:
  a colorful wallpaper never tints it.
- [ ] The window's height follows the selected tab (all three tabs are as tall as their content, with no large empty
  area; the Layout tab grows and shrinks when the Screen Recording notice appears or is closed, without the section
  bands moving). Switching tabs cross-fades the content (about 0.2 s) while the window
  animates to the new height with its top edge and the toolbar staying put: no flicker, no content jump, no layout
  pop, no stutter, also on the first visit to each tab and when clicking tabs in quick succession (the last clicked
  tab ends up shown cleanly). A notice appearing in a tab (Behavior's Accessibility notice) grows the window too. With System Settings → Accessibility → Display → Reduce motion on, switching is
  instant. The window title follows the selected tab. Returning to Layout expands the menu bar only after the fade.
- [ ] **First switch to Layout after a launch (known issue: "a ~0.25 s stall")**: delete the image cache, launch with
  `FROST_TEST_FRAME_PROBE=1`, open Settings on About, wait a second and switch to Layout: `frame-probe tab-layout` shows
  no hitch during the fade (no `at=` entry below ~300 ms; the Layout tab was built off screen ~0.4 s after the window
  opened) and gaps of at most ~50 ms afterwards, while the editor fills in (`notes=editor@…,editing@…,settled@…,
  owners@…,captured@…`). Measured in the VM (4 fresh launches each): 84–201 ms of hitches with gaps up to 68 ms
  before (230–640 ms in worse runs, gaps up to 139 ms), 45–103 ms with gaps up to 50 ms after.
- [ ] **The window's top-left corner stays put across opens**: open Settings on About, close it, relaunch Frost with
  Layout as the last tab and open Settings again: the window's top edge and left edge are where they were (it isn't
  centered again); it is centered only the very first time, or when its display is gone.
- [ ] Switch the system between Light and Dark Mode: the Settings window, onboarding window and Frost Bar update
  immediately; images in the layout editor and Frost Bar refresh with the appearance (white / black glyphs never end
  up on a background of the same color; monochrome glyphs in the Frost Bar are tinted by the glass's actual
  brightness). Tiles keep showing their previous images until the new captures arrive (no blank tiles), and an open
  Frost Bar doesn't resize unless an item's width really changed.
- [ ] The snowflake in the menu bar matches the neighboring Wi‑Fi / Control Center / third-party icons in size and
  weight, and is vertically centered in both light and dark menu bars; it doesn't animate on expand / collapse.
- [ ] Behavior tab (sections **Menu Bar** and **General**, native switches, no per-row icons): **Show hidden icons**,
  **Automatically rehide** with **Rehide delay** (dimmed while rehide is off), **Keep icons in their sections** and
  **Launch at login** work; an inline error appears if enabling launch at login fails. Switching the display mode
  changes its one-line explanation instantly: the row keeps its height and the rows below don't move; no overlapping
  text.
- [ ] Layout footer: the Screen Recording notice, the "N icons are off-screen" note and the ⌘-drag tip are separate
  lines that can all show at once and never overlap or cross-fade into each other. The off-screen note appears only
  after the count has stayed above zero for about 5 s and leaves 10 s after it dropped to zero: with FakeItems'
  `live` mode (an icon hidden 4 s of every 20 s) the footer and the window height stay still for minutes.
- [ ] About tab: the real app icon (not a symbol), "Frost" and the version; **Updates** (automatic checks; a row
  "Last checked: today at 15:58" / "Never checked" with **Check for Updates…** trailing, updating after a check) and
  **Permissions** (Accessibility and Screen Recording with Granted / Grant Access / Open System
  Settings + Relaunch) in grouped sections; nothing truncates in zh-Hans. In zh-Hans with an English region the
  last-checked date is in Chinese too (not "Today at 6:31 AM" inside the Chinese label), with the region's clock
  setting.
- [ ] About → Screen Recording → **Grant Access** (no TCC entry yet): while the system prompt is up the row shows a
  small spinner, not "Needs Relaunch"; once the prompt closes (either button) it offers **Open System Settings** and
  **Relaunch**.
- [ ] App icon: the icon is crisp in Finder, the About tab, Login Items and the System Settings privacy lists; on
  macOS 26 it is not placed inside a gray rounded "container" (the asset catalog icon matches the system icon shape).

## 7. Displays

- [ ] Notched vs. non-notched displays: sections, expansion and Frost Bar position are correct on both; notched
  displays default to Frost Bar, non-notched displays to In Menu Bar.
- [ ] With the menu bar set to hide automatically, expand / collapse and the Frost Bar position work normally.

### 7.1 Multiple displays (real Mac: built-in notched display + external display)

Background: every status item has one window on each display's menu bar; the **real window** (titled with its
autosave name) is on the display with the **active menu bar**, and swaps places with the replica when another display
is clicked / focused. Frost manages the display with the active menu bar (`MenuBarDisplayResolver`; measurements in
the "Multiple displays" section of `docs/macos-behavior.md`). This has been verified in the VM with virtual
displays (same 30 pt height; right / left / very wide left / below); on a real Mac the two menu bars have different
heights (39 / 30 pt), which takes the height-based path, so what needs verifying is "follows the active menu bar" and
how the freeze frame and click forwarding behave on the external display.

Preparation: connect the external display, note the arrangement and each display's resolution in System Settings →
Displays → Arrange; leave "Displays have separate Spaces" at its default (on). Logs:
`/usr/bin/log stream --info --predicate 'subsystem == "dev.frost.Frost"' --style compact | grep -E 'managing|icon moved|could not be told|captured|replica'`.
Window list (read-only): `swift scripts/vm/dump-status-windows.swift --all` (columns: y, then x, width, height,
on-screen, windowID, title; real windows are titled with their autosave name, replicas with a bundle ID or nothing).

- [ ] **External display on the right, built-in display active**: click the snowflake on the built-in display → the
  Frost Bar opens below the built-in snowflake with the same number of items as with the external display unplugged,
  and no `?` placeholder items (which appear when a replica is mistaken for an item); log
  `managing the menu bar of display <built-in ID>`, and once settled no `could not be told apart` (or the last one is
  `0 status window(s)`).
- [ ] **Click the snowflake on the external display**: log `the Frost icon moved from display <built-in> to
  <external>`, `managing the menu bar of display <external>`; the panel opens **below the external display's
  snowflake** (right edge aligned with the snowflake, top edge at the bottom of the external menu bar), with the same
  content as the previous step. `dump --all`: the `FrostIcon` row is now within the external display's x range.
  **It must open on the first click** (seen on a real Mac: the first click only switched the active menu bar): log
  `mouse down on a Frost icon replica …`; if the system doesn't deliver the click to the button, after about 0.3 s
  `click on the Frost icon replica on display <external> did not reach the button; handling it`, and the panel opens
  anyway. It opens exactly once and doesn't open and immediately close (no `ignoring a late Frost icon action`
  followed by a close). Try each once: both directions (external → built-in, built-in → external), left click /
  right click (menu) / ⌥-click, and In Menu Bar mode, clicking by hand (not synthesized events).
- [ ] **Snowflake click during a live refresh round** (Display mode Automatic: Frost Bar on the notched display, In Menu
  Bar on the external one): with the Frost Bar open on the built-in display, click the snowflake on the external
  display: its Hidden section expands and stays expanded (log `Frost icon clicked during a temporary expansion` /
  `ending a temporary expansion in state 1` when the click lands during a round); repeat with ⌥: everything expands
  and stays. The menu bar never visibly expands and collapses on the built-in display.
- [ ] **No flicker on either display**: keep the panel open on the external display for 10 s (colorful wallpaper, clock
  showing seconds): no expansion left of the external snowflake, no once-per-second brightness change, and the
  external clock ticks as usual; the same for the built-in menu bar (its freeze frame covers only the area left of its
  own snowflake replica). Record each display separately.
- [ ] **Click forwarding on the external display**: click a third-party app's menu item in the panel: the item moves
  to the right of the external snowflake and its menu opens on the **external** display; after closing, the item
  returns to the Hidden section (back to a negative x in `dump --all`). Also try popover items (Focus / Battery) and
  closing by clicking outside.
- [ ] **Switch back to the built-in display**: click a window on the built-in display → log
  `moved from <external> to <built-in>`; open the Frost Bar from the built-in display again, and the content is
  correct.
- [ ] **Layout editor**: once with the built-in display active and once with the external display active
  (right-click the snowflake on the external display → "Settings…"): no duplicate items in the three sections; drag an
  item from Hidden to Visible and back, and the menu bar stays in sync.
- [ ] **External display on the left** (drag it to the left in Arrange, top edges aligned): repeat the first four items.
- [ ] **Known risk (c), very wide display on the left**: external display on the left with the resolution set to "More
  Space" (wider than about 3,500 pt, e.g. 3840×2160): the built-in display's pushed-out items (from x ≈ −3,500) fall
  within the external display's rectangle. Open the Frost Bar with the built-in display active: **none** of the
  Hidden items are missing (older versions dropped them).
- [ ] **Hot-plugging**: unplug the external display with the panel open → the panel closes; unplug it while it has the
  active menu bar → the log switches back to the built-in display, and the Frost Bar / In Menu Bar work normally;
  everything works again after reconnecting.
- [ ] **First click after connecting a display**: connect the external display (in the VM: start
  `guest-virtual-display`) and click its snowflake right away (within 2 s): the first click works (log `display
  configuration changed`, then `mouse down on a Frost icon replica`).
- [ ] **Mirroring** (Displays → Mirror): there is only one menu bar, and behavior is the same as with a single display.

## 8. Quit, relaunch and persistence

- [ ] Quit Frost (right-click menu or ⌘Q): all hidden items become visible again (the system restores them once the
  separators are gone).
- [ ] **Quit during moves**: in the layout editor drop several items quickly (moves queue up) and press ⌘Q right after
  the drops: Frost quits within about 6 s, no item is left half-dragged, no queued drop starts after the quit began
  (log `shutting down: no new move transactions`), the cursor is where it was, and no mouse button is left pressed
  (click something afterwards). Same while the Frost Bar is forwarding a click (menu open): the item moves back first.
- [ ] Relaunch Frost: the section layout is kept (every item is still in its section); onboarding doesn't appear again.
- [ ] Force-quit Frost (`kill -9`) and relaunch: the layout is kept, with no leftover blank separators.
- [ ] **Icons keep their sections** (Settings → Behavior → **Keep icons in their sections**, on by default): put a
  third-party item in Hidden, quit its app and make it come back in Always Hidden (in the VM: quit FakeItems,
  `defaults delete dev.frost.FakeItems "NSStatusItem Preferred Position FIMenuA"`, relaunch it). Within a few seconds
  Frost moves it back to Hidden (log `moved … back to hidden: its app re-added it elsewhere`); the same happens when
  Frost itself is launched after the app. Then ⌘-drag the item into Visible yourself (expand first) and collapse: the
  move is kept, not reverted (log `remembering … in visible: moved by the user from hidden`), and the next relaunch of
  the app puts it back in Visible (right of the snowflake). A drop in the layout editor is remembered the same way
  (`dropped in the layout editor`). Clicking an item in the Frost Bar (moved out and back) changes nothing. With the
  setting off, a re-added item stays where the system put it.
- [ ] Open the Frost Bar after a relaunch / reinstall: images from the disk cache are shown directly and the menu bar
  doesn't expand. Force-quit Frost while it is recapturing (freeze frame showing): the freeze window disappears with
  the process and the menu bar returns to normal (collapsed after relaunch).
- [ ] **Disk cache writes are throttled**: with a changing item (a clock with seconds) in Hidden and the Frost Bar open
  for 2 minutes, its PNG in `~/Library/Caches/dev.frost.Frost/items/` is rewritten at most about once a minute
  (`ls -lT`); after closing the panel the file holds the newest capture (and again after quitting).
- [ ] Launch at login: turn on **Launch at login**, log out and back in: Frost starts automatically with the layout
  kept; after turning it off, it no longer starts automatically.

## 9. Revoking and restoring permissions

- [ ] **No Accessibility** (user chose Not Now): the Behavior tab's notice has a **Grant Access** button; the Frost icon's
  right-click menu starts with **Grant Access…**; the Frost Bar panel's "Accessibility Required" button requests
  directly. After granting in System Settings (Frost not frontmost), the very next click on the Frost icon uses the
  Frost Bar mode (the Accessibility change notification refreshes it; the click handler refreshes too).

- [ ] Revoke Accessibility while running: the Frost Bar and layout editor show placeholders, and hiding / showing still
  works; a move in progress fails safely (no hang, no stray cursor movement).
- [ ] Revoke Screen Recording while running: images stop updating, and app icons or placeholders are shown; after
  re-granting and relaunching, images come back.

### 9.1 Accessibility only (no Screen Recording)

VM: `scripts/vm/vm-grant-tcc.sh --revoke screen`, then relaunch Frost (`vm-run.sh`); `--grant screen` restores it.
Evidence goes under `build/vm-shots/no-screen-recording/`.

- [ ] The Frost Bar opens (Automatic on a notched display, or Frost Bar mode) and shows a tile for every hidden icon:
  the owning app's icon, an SF Symbol for system items (Spotlight, Control Center modules), the text of text items on
  wide tiles, and a short label under the icon when several icons of one app would look the same. No live refresh
  runs (log `live refresh: … skipped permissionsMissing`), and the menu bar never expands.
- [ ] Short text items (a seconds counter, a percentage) read in full on their tiles, in the Frost Bar and the layout
  editor.
- [ ] A small "Grant Screen Recording to see real icons" row sits above the footer; clicking it closes the panel and
  requests directly (no onboarding window; after a request it offers **Relaunch** and **Open System Settings**); its close button hides it for good (also in the layout editor), `screenRecordingHintDismissed`.
- [ ] Clicking a tile opens the item's menu / popover; right-click or Control-click opens its secondary menu; the item
  moves back afterwards.
- [ ] The layout editor shows the same fallback tiles and the same hint in its footer; drags between sections work;
  the clock and the Control Center button carry a lock and can't be dragged.
- [ ] Keep icons in their sections: move an app's icon to another section, quit the app and reset its saved positions,
  relaunch it: Frost moves the icon back (log `moved … back to …: its app re-added it elsewhere`).
- [ ] Upgrading from a version that keyed items by window title (`itemSections.v1` / `knownItemIdentities`): on the
  first launch with Screen Recording, log `moved N remembered section(s) to the items' current identities`, and
  `itemSections.v2` / `knownItemIdentities.v2` / `itemTitles.v1` are written; cached images in
  `~/Library/Caches/dev.frost.Frost/items/` are moved to the new keys (their metadata gets a `key`). Without Screen
  Recording, an app's only icon still takes over its remembered section; apps with several icons wait for titles and
  aren't treated as new meanwhile.
- [ ] Grant Screen Recording and relaunch: real images replace the app icons and the hint is gone.
- [ ] After a rebuild (same signing certificate), grants remain valid and don't need to be granted again.

## 10. Automatic updates (Sparkle)

Verify in the VM with two release builds that have different version numbers (`scripts/release/release.sh`); for a
local update feed, see "Testing an update in the VM" in `docs/releasing.md`.

- [ ] **Automatically check for updates** in Settings → About is on by default; after turning it off,
  `defaults read dev.frost.Frost SUEnableAutomaticChecks` is 0, and it is still off after a relaunch.
- [ ] Right-click the snowflake → "Check for Updates…" (or **Check for Updates…** on the About tab): when already up
  to date, Sparkle says so; while a check is in progress, the menu item and the button are disabled. From the
  snowflake menu, Settings opens on About first (its "Last checked" row in view) with Sparkle's window above it;
  "Update Available…" only brings the update window back.
- [ ] **Errors**: with an unreachable feed (`defaults write dev.frost.Frost SUFeedURL http://127.0.0.1:9/appcast.xml`),
  "Check for Updates…" shows Sparkle's "Update Error!" alert in front; clicking the snowflake while it is up brings it
  to the front (log `Frost icon clicked while a Sparkle alert is up`) instead of doing nothing. A scheduled check with
  the same feed (`SULastCheckTime` older than the interval, then relaunch) fails silently: no alert. Reset with
  `defaults delete dev.frost.Frost SUFeedURL`.
- [ ] When a new version is available, the update window appears (release notes come from CHANGELOG.md); install the
  update → download, verification, and after "Install and Relaunch" Frost relaunches with the new version (version
  number on the About tab), **Accessibility and Screen Recording grants are still valid**, and the layout is kept.
- [ ] **Gentle reminder** (scheduled check while Frost is not in front): with a newer version on the local feed,
  `defaults write dev.frost.Frost SUScheduledCheckInterval -int 3600` and
  `defaults write dev.frost.Frost SULastCheckTime -date "$(date -u -v-55M '+%Y-%m-%d %H:%M:%S +0000')"`, launch Frost
  and keep using the VM (an idle Mac makes Sparkle show the update in focus instead) until the check runs about
  5 minutes later: no window is pushed to the front; a small accent-colored dot appears on the snowflake (log
  `update … available (scheduled check); showing a reminder`), and its right-click menu shows "Update Available…"
  instead of "Check for Updates…" (localized in Simplified Chinese too). Choosing it brings the update window to the
  front; after dismissing ("Remind Me Later" / "Skip This Version") or installing, the dot and the menu item go away.
  Reset with `defaults delete dev.frost.Frost SUScheduledCheckInterval`.
- [ ] The updated app has no quarantine attribute (`xattr -p com.apple.quarantine /Applications/Frost.app` reports an
  error), and no Gatekeeper prompt appears at launch.

## 11. macOS 27 (the accessibility backend)

In the macOS 27 VM (`testing-vm.md`, "macOS 27 VM"), with several third-party icons running (FakeItems +
FakeItems Demo). Compare the menu bar with Frost quit and with Frost running: on 27 there are no per-item windows, so
compare the menu bar extras' AX frames and the pixels of the bar (`testing-vm.md`, "Verification techniques").

- [ ] Launch: the log says `managing the menu bar of display …`; the snowflake appears left of the system's items and
  **both dividers end up at the left end of the trailing area** (`placing Frost27.HiddenDivider …`), so the icons the
  bar still draws stay together on the right, next to the snowflake. No `isn't supported` line.
- [ ] The three states hold: collapsed hides the most, expanded (click) shows more, ⌥-click shows everything. Check it
  on screenshots of the bar, not on AX frames — a pushed-out icon keeps reporting its old frame.
- [ ] Frost Bar (left click with the display mode set to Frost Bar): it lists the icons in the bar's order, **without
  a count** and without Frost's own dividers, and its footer says "Menu bar icons". Clicking one opens its real menu;
  a click outside closes the panel. Without Screen Recording the tiles show the owning app's icons.
- [ ] Settings → Layout: the three bands hold **the arrangement**, not something read from the bar; with nothing
  arranged yet every icon is in Visible and the footer explains that macOS decides how many icons the menu bar shows.
  Drag a tile into Hidden: the icon really moves in the menu bar (log: `direct ⌘-drag … verified against the order the
  menu bar reports`), and the band keeps it after closing and reopening the editor and after relaunching Frost.
- [ ] A drop into an empty band is not reported as a failure when the icon did move (the destination is one of Frost's
  own dividers, an invisible 8 pt line: "on the divider's hidden side" counts as reached).
- [ ] Behavior and About are the macOS 26 windows; Check for Updates… works.
- [ ] English and Simplified Chinese, Light and Dark Mode.

## 12. A macOS version without a backend (notice only)

For any macOS version Frost has no backend for (`PlatformSupport.backend` returns `.noticeOnly`: everything that is
not 26 or 27 until it has been measured). Exercise it in the macOS 26 VM with
`make vm-run FROST_ENV="FROST_TEST_UNSUPPORTED_OS=1"` (Debug builds).

- [ ] Launch: the log says `macOS <version> isn't supported: leaving the menu bar alone (snowflake only)` once; there
  are no `managing the menu bar` / Frost Bar warm-up lines.
- [ ] Only the snowflake is added to the menu bar: no Frost separators, and every other icon keeps its order (the same
  as with Frost quit, plus the snowflake). Nothing expands, collapses or moves at any time, also with Settings open.
- [ ] A left click and a right click on the snowflake both show its menu: a disabled first item "This version of macOS
  isn't supported yet" with "Frost can't hide icons on macOS <version>. An update is on the way." below it, then Settings…,
  Check for Updates… and Quit Frost. No Frost Bar, no Grant Access.
- [ ] Settings → About shows the same notice above Updates and no Permissions section; Layout shows the notice instead
  of the editor; Behavior's Menu Bar controls are disabled with the explanation as their footer, while Launch at login
  still works.
- [ ] First launch (`defaults delete dev.frost.Frost`): no onboarding window; `hasCompletedOnboarding` stays unset, so
  a release that supports this macOS still runs onboarding.
- [ ] Check for Updates… (menu and About) works, and so do automatic checks.
- [ ] Upgrade: install the previous release first, launch it so it creates its separators, quit, then install this
  build over it: the separators are gone, the icons are in the same order as with Frost quit, no crash
  (`vm-crash-check.sh`). Their saved `NSStatusItem Preferred Position` values stay in the defaults.
- [ ] English and Simplified Chinese, Light and Dark Mode.

## Known limitations

- A macOS version Frost has no backend for isn't supported yet: Frost only shows the snowflake with a notice there
  (section 12, and [`macos-behavior.md`](macos-behavior.md), "macOS 27").
- On macOS 27 Frost cannot tell which icons the menu bar drops: how many leave it depends on what is in your bar, so
  the Frost Bar lists your icons without claiming which are hidden, and the layout editor's sections are the
  arrangement you set there.

- Without Screen Recording, an icon's identity comes from its AX attributes. An app whose icons have neither an AX
  identifier nor a description (or help) is identified by the order in which it created them; one whose icon's
  description changes all the time (e.g. it includes a live value) gets a new identity whenever it changes, so after a
  relaunch its section may not be restored. With Screen Recording, the window title last seen with an identity lets
  Frost follow such changes.

- The image cache is keyed by the system's light / dark appearance (`NSApp.effectiveAppearance`), not by the menu bar
  brightness that the wallpaper determines: in Light Mode with a dark wallpaper, white glyphs are cached, but still
  under the "light" key. The Frost Bar re-tints monochrome glyphs and the layout editor picks the background by glyph
  brightness, so display is unaffected; a new capture overwrites the old one while the item is on screen.
- While the Frost Bar is open, for about 0.2 s every second (occasionally about 0.7 s, see below) the menu bar left of
  the snowflake is a freeze frame: changes there during that time (e.g. menu titles after switching apps, other apps'
  item updates in the Visible section) appear slightly later; the snowflake and everything to its right (clock,
  Control Center) are unaffected. The freeze frame passes clicks through, but no refresh happens while the pointer is
  over that part of the menu bar or a mouse button is held (a cycle in progress ends early).
- Items behind the notch are captured by moving them out in the background (one at a time, ~1 s each, under a
  whole-menu-bar freeze frame, while the user isn't using the menu bar). Meanwhile the clock pauses for that second, a
  click on the menu bar left of (and on) the snowflake is taken by the freeze frame (on the snowflake it is replayed
  afterwards; elsewhere the user clicks again), and a menu can't be opened over it. Images of such items that change
  are refreshed only every ~10 minutes; one that turned out not to change isn't recaptured during that run.
- While an item is changing width (e.g. the digits of a text item changing), the system occasionally takes about
  0.5 s to apply Frost's collapse length change, and that cycle's freeze frame stays up for about 0.7 s (still no
  visible expansion).

- Multiple displays have only been verified with virtual displays in the VM (same 30 pt height; right / left / very
  wide left / below; Frost Bar, freeze frame, click forwarding and layout editor moves with the active menu bar on the
  secondary display). For a real Mac (39 pt notched display + 30 pt external display), see 7.1.
  Other cases: if the user happens to click another display during a move (the active menu bar changes displays and
  all real windows swap places), that move may fail and is retried / moved back later by the existing mechanisms;
  three or more displays in the same row with the same height are covered only by unit tests; when an app's item has
  different widths on two displays, Frost relies on "end-to-end adjacency", falling back to geometry when that is
  inconclusive (log `could not be told apart`).
- Popups opened through the Frost Bar that don't close on an outside click: transient popovers of apps that only use
  cooperative activation are solved by the activation hand-off (verified in the VM). Remaining cases: when the
  hand-off doesn't apply (Frost's Settings window is open while Frost isn't frontmost, or the target app can't be
  activated), the "click outside" fallback takes over: when the target app isn't frontmost, Esc has no effect, so
  after a grace period (0.3 s) Frost clicks the item again directly; the popover disappears after about 0.9 s (about
  0.5 s of which is the popover's own closing animation) and the item moves back after about 1.1 s (previously Esc was
  sent first, taking 1.5–2 s). Only when the target app is frontmost and the popover still doesn't close is Esc sent
  first (1 s grace + Esc, about 1.6 s). Popups the fallback can't close either (non-transient, ignoring Esc and a
  second click, or with a translucent window mistaken for one that is fading out) are moved back only when the
  60-second limit is reached. The fallback's Esc and second click wait while a mouse button is held or another menu
  is open, so a popover may stay open until the user lets go or that menu closes. Apple system items and items of
  unknown ownership get neither the hand-off nor the fallback. Menus are unaffected: they have no time limit and move
  back as soon as they close.
- Keeping icons in their sections only remembers the section, not the position within it: a re-added icon goes to
  the section's boundary (right end of Hidden / Always Hidden, right of the snowflake in Visible); only an icon Frost
  itself had moved out when it quit (a background capture) goes back next to its old neighbours. Icons are recognized
  by app and status item name; when several current items of an app share a name, Frost neither remembers nor
  restores them. A ⌘-drag in the menu bar is noticed at the next scan (e.g. when the menu bar collapses); if Frost
  quits before that, the next launch may move the icon back to its previous section. Moves made while Frost isn't
  running are treated the same way.
