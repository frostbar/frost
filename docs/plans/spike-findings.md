# Spike Findings (macOS 26.6.2, build 25G83)

("Task N" in this document refers to task numbers in an early implementation plan that is not included in the
repository.)

Program: `Spikes/MenuBarSpike/main.swift` (`swiftc -swift-version 6 -O`, run from Terminal so it inherits Terminal's
Accessibility + Screen Recording permissions). It was run 12 times in total (a full run takes about 97 s, well under
the 180 s watchdog). Every exit removed all status items and deleted the UserDefaults seeds; the cursor was restored
to its original position every time. Apart from reading CGWindowList and counting windows in step 8, **no third-party
item was moved or clicked**.

Test environment:

| | Main display (built-in, with notch) | Secondary display (external, 1920×1080) |
|---|---|---|
| CG bounds | `(0, 0, 1800, 1169)` | `(1800, 0, 1920, 1080)` (to the **right** of the main display, top edges aligned) |
| Menu bar window height | 39 pt | 30 pt |
| Notch (CG coordinates) | x 790–1010 (`auxiliaryTopLeftArea.maxX` … `auxiliaryTopRightArea.minX`) | none |

`NSStatusBar.system.thickness` returns 22, which **does not match the real menu bar height (39)**. Do not use it for
geometry.

---

## Status item order and seed values; do windowNumber and CGWindowList agree?

**windowNumber and CGWindowList do not agree.** `button.window.windowNumber` is `k << 32` (`0x100000000`,
`0x200000000` …, in creation order), not a CG window ID. `CGWindowID(windowNumber)` **overflows and traps** (that is
how the first run crashed).

Reliable identification methods (both verified in every state, including when pushed off screen):

1. **By title**: on the main display the window's `kCGWindowName == autosaveName` (e.g. `SpikeIcon`), layer 25, owner
   Control Center (pid 31837), consistent with the known facts from Task 0.
2. **By frame**: `button.window.frame` converted to CG coordinates is **exactly equal** to the CG frame (x/y/w/h),
   even when pushed off screen (e.g. `(-3487, 0, 29, 39)`).

The replica windows on the secondary display (one per item, different IDs, 30 tall) are titled with the **process
pid string** (e.g. `"50793"`). That is because the spike is an executable without a bundle; per known fact 2, an app
with a bundle should get its bundle ID as the title (not verified for Frost itself).

**Seed values**: `V=0, Icon=1, H=2, X=3, AH=4, Y=5` produce the target order `[Y][AH][X][H][Icon][V]` in one go, with
no dragging. The rules:

- Smaller values sit further right.
- The system does not rewrite seed values when items are created.
- Seeds 0…5 place the spike items to the right of all third-party items and to the left of the Control Center system
  items (`BentoBox-0`, `Clock`).
- When only some items are seeded, as Ice does (`Icon=0, H=1`), the unseeded items **get no value written** and appear
  at the **far left** of all status items, later ones further left (x 929–1054). On a crowded notched display this puts
  them under the notch (`onscreen=false`).
- `AH=10000` behaves the same as "no seed" (lands left of all existing items), except that the value is kept.

Other observations:

- **After a ⌘-drag the system rewrites the Preferred Position** to "distance from the item's right edge to the
  screen's right edge + 2". For example V's maxX is 1616, giving `1800 − 1616 + 2 = 186`; Icon gets 215, H 244. When
  moved in the collapsed state, the value includes the 5016 pt wide separator (e.g. X=5260, Y=10305). Ordering
  semantics are unaffected.
- **`NSStatusBar.system.removeStatusItem` deletes the item's `Preferred Position` key**: all 6 keys exist before the
  removal and the domain is `[:]` afterwards. A process that just exits or crashes does not delete them (the keys were
  still there after the run that crashed).
- **Leftover windows**: after an app quits, its status item windows may stay in CGWindowList. For example
  `dev.frost.Frost` with width 0 on the secondary display; `Item-0` at 38 pt with `onscreen=false` on the main display.
- AX: this process's `kAXExtrasMenuBarAttribute` has 6 children; `AXTitle` is the button title, `AXDescription` is
  empty.
  - A regular item's AX frame is CG `x − 1`, `w + 2`, `y = 7.5`, `h = 24`.
  - A separator's AX frame is CG `x + 7`, `w = length + 2` (length 8 → 10, 0 → 2, 10000 → 5002).
  - midX differs from CG by ≤ 1 pt, so **midX matching with a 4 pt tolerance works**, including for items pushed off
    screen (negative x).

## Frames / order / settle time / enumerability of length=0 in the four section states

Main display CG frames (x, width). The table shows one run's measurements; all other runs were identical:

| State | H.len / AH.len | Y | AH | X | H | Icon | V |
|---|---|---|---|---|---|---|---|
| editing | 8 / 8 | 1452, 29 | 1481, **24** | 1505, 29 | 1534, **24** | 1558, 29 | 1587, 29 |
| collapsed | 10000 / 10000 | **−8532** | −8503, **5016** | **−3487** | −3458, **5016** | 1558 | 1587 |
| expanded | 0 / 10000 | −3532 | −3503, 5016 | 1513 | 1542, **16** | 1558 | 1587 |
| expandedAll | 0 / 0 | 1468 | 1497, **16** | 1513 | 1542, **16** | 1558 | 1587 |

- **Window width = length + 16.** Length 8 gives 24 pt; length 0 still leaves a **16 pt gap** (not 0).
  - A `length = 10_000` window is **truncated by the system to 5016 pt**, i.e. it pushes items about 5000 pt to the
    left. That is enough for an 1800 pt wide menu bar; **a menu bar wider than about 5000 pt might not be cleared
    completely**, which could not be tested on this machine.
- Pushed-off items have `kCGWindowIsOnscreen = false`; the 5016 pt separator itself is also `onscreen=false`.
- **The wide separator does not intercept clicks**: when collapsed, a hit test at (300, 19) hits the front app's
  `AXMenuBarItem "Help"`; 60 pt left of Icon hits `AXMenuBar`; the topmost CG window at that point is Window Server's
  `Menubar` (layer 24).
- **Order is always preserved**: 6 transitions × several runs, never out of order. **All windowIDs stay the same in
  every state**, and **a length=0 separator is still enumerable in CGWindowList** (16 pt, `onscreen=true`) and readable
  through AX (width 2).
- **Settle time** (scanning every 50 ms after setting the length):
  - First frame change observed at 54–61 ms.
  - "Two consecutive identical scans after the change" at 108–118 ms.
  - The scan at 0.5 s always equaled the final result.
- **Positions of pushed-off items**:
  - Main display: X = −3487, Y = −8532.
  - Secondary display replicas: X′ = −1569, Y′ = −6614.
  - All of them lie **outside** every display rectangle, because the secondary display is to the right of the main one
    and there is no display at negative x. **If the secondary display were to the left of the main one**, its replicas
    might fall inside its rectangle; this could not be tested on this machine.
- **Zero-width approach** (step 2b, H in the expanded state):
  - Setting the title to `""` still gives 16 pt.
  - Ice's technique works: find the constraint on `button.window.contentView` with `secondItem === button.superview`
    (`NSStatusBarContentView.width == NSView.width + 16`), set `isActive = false`, then
    `window.setContentSize(width: 1)`; the window becomes **1 pt** wide.
  - Reactivating the constraint restores 16 pt. The window stays enumerable and the order is unchanged.

## Capture: visible / off screen / after restoring

| Case | Result |
|---|---|
| (a) X visible (expanded) | Success, 58×78 px (2×), 124/4524 pixels with alpha > 128. The first capture including `SCShareableContent` takes 99–107 ms, each later one 25–30 ms. White glyph on a transparent background. |
| **(b) X pushed off (collapsed)** | **Failure**. `SCShareableContent(onScreenWindowsOnly:false)` lists the window (`frame=(-3487,0,29,39)`, `isOnScreen=false`), but `SCScreenshotManager.captureImage` throws `SCStreamErrorDomain -3811 "Failed to start stream due to audio/video capture failure"`. `CGWindowListCreateImage` called through dlsym also returns nil. |
| (c) After restoring | Success, identical to (a) (124 px). |

**Gate conclusion: the Frost Bar cannot capture hidden items directly.** Items must be captured and cached while
visible, or expanded temporarily. Items covered by the notch are `onscreen=false` even in expandedAll and cannot be
captured either.

## ⌘-drag moves: working event combinations, wait times

**On screen (expandedAll)**: all 6 event combinations from the plan **succeeded**, in both directions (X → right of
Icon, X → left of H). Full runs 12/12; across 100+ moves over several runs only 1 failed, see below.

1. Original plan: session tap, both window fields, 10 dragged events
2. Original + `CGWarpMouseCursorPosition(start)` before the drag
3. Without `mouseEventWindowUnderMousePointer`
4. Without both window fields
5. `.cghidEventTap`
6. Ice style: only down → up, no dragged events; fields `0x33` and `eventTargetUnixProcessID` set; mouseUp carries the
   target item's windowID

**Routing (key finding)**: put the mouse-down physically on Y but put X's windowID in the fields, then drag to the
right of Icon.

| Combination | Item that gets dragged |
|---|---|
| Original plan (`mouseEventWindowUnderMousePointer*` fields) | **Y**: routed by position, fields ignored |
| Ice style (with `0x33`) | **X**: routed by windowID |
| Ice style without `0x33` | Y (by position) |
| Ice + 10 dragged events | X |
| Ice, but mouseUp carries the dragged item's own windowID | X |
| Only `0x33` (no pid field) + the plan's dragged steps | X |

Conclusions:

- **Setting `CGEventField(rawValue: 0x33)! = dragged item's windowID` on the mouse-down (and following events) routes
  by windowID.** `eventTargetUnixProcessID`, dragged events and the mouseUp windowID are all unnecessary. The other
  fields have no effect on routing.
- **The drop position is determined by the mouseUp event's location**, using the raw coordinates: even off screen,
  where the cursor would be clamped to x=0, the raw coordinates are used (see the next section).
  - The endpoints `leftOf T = (T.minX + 1, T.midY)` and `rightOf T = (T.maxX − 1, T.midY)` are both correct.
  - With H at length 0 (16 pt window), dragging to `H.minX + 1` also lands correctly to the left of H.

**Wait times** (polling every 25 ms after the last event):

- The events themselves take 250–285 ms for the 10-step dragged version and 74–81 ms for Ice style (down, wait 50 ms,
  up).
- **The new position appears in CGWindowList with the correct order after 32–40 ms** (the first or second poll).
- **After an on-screen move, all frames settle (animation finished) after 390–540 ms**; moves between off-screen
  positions have no animation and settle after 94–152 ms.
- The cursor was restored exactly every time.

**Occasional failure**: in run4, a location-routed move right after another drag had no effect at all (no frame
change). About 1 s later two Control Center layer-500 windows (37×39, probably drag ghosts) were seen at that position;
a retry a little later succeeded. **ItemMover must keep retries** and wait for frames to settle between attempts.

**Later measurement (VM, macOS 26.6.2; supersedes the fixed 50 ms down → up interval)**: the mouse-down *lifts* the
dragged item — its window jumps to the cursor (`y` = the menu bar's midY) 13–96 ms after the event, the layer-500 drag
windows appear ~35 ms later — and the system reserves its slot **at the mouse-down position** (next to the Frost icon).
The windows between the item's old slot and that slot then slide over by the item's width to close the gap (~0.4 s on
screen; in the collapsed state the Frost icon itself slid). The mouse-up is placed against those current positions.
Consequences with the old fixed timing: a mouse-up before the lift is ignored (no move at all; about 1 in 4 at 50 ms,
2 in 30 at 150 ms, none at 200 ms), and when the target is one of the sliding windows the item lands one slot off
(moving rightwards within Hidden / from Always Hidden into Hidden ended up right of the target, moving leftwards within
Visible ended up left of the slot). `ItemMover` now polls the windows while the button is down (`DragRelease`): it
posts the mouse-up once the item has been lifted, and when the target may slide (it lies between the item and the
Frost icon) only after the windows have stopped moving, aimed at the target's frame at that moment. Measured over 40+
layout editor drops: every one landed on the first attempt; moves whose target doesn't slide (the Frost Bar's move out
and back) still release after 40–70 ms, the others after 300–500 ms.

**Later measurement (VM, macOS 26.6.2; Frost Bar click latency)**: on the mouse-up the dragged item does **not** slide
into place: its window jumps from the cursor straight into its new slot within a few ms (sometimes through one
intermediate frame that still overlaps its right neighbor). What animates for the next ~0.4 s are the windows **left**
of the slot (the Frost icon and the separators making room); the menu bar is right-aligned, so nothing right of the slot
moves. A menu or popover opened as soon as the item is in its slot is anchored at the item's final position (80+
forwards, menus left-aligned with the item, popovers centered under it), even while the icon left of it still slides.
So the click forward clicks once the item has landed (`LandingDetector`: in the right order, on the row, touching the
window on its right, the same frame in two snapshots 8 ms apart) instead of waiting for every window to stop moving.
Rarely the item stays lifted for ~0.5 s after the mouse-up and lands only then; the landing wait simply lasts longer.
Breakdown of a click on a tile → menu before the change (median of 80 forwards): tile mouse-up → Frost's action ~15 ms,
→ mouse-down ~30 ms, lift ~20–30 ms later, mouse-up 3 snapshots (~30 ms) after the lift, then 320–470 ms waiting for
all windows to settle and 90 ms re-checking the item's frame (2 × 40 ms), and ~10 ms from the click (AXPress or HID)
to the menu window: 663 ms median, 811 ms p90. A click while a live refresh round was taking its freeze-frame
screenshot waited ~75 ms for the round; the screenshot is now taken before the round takes the move transaction, so
such a click starts its move at once and the round gives up without showing anything. After both changes (VM, 160+
forwards of menus and popovers from Hidden and Always Hidden, no misplaced menu, every item back in its slot): 194 ms
median, 262 ms p90; ~140–190 ms with the panel open for a few seconds (tile mouse-up → Frost's action ~15 ms, mouse-down
+15 ms, lift +25 ms, mouse-up +30 ms, landed +35–45 ms including a fixed 20 ms after the mouse-up, click +5 ms, menu
+15–25 ms), ~205–250 ms when a live refresh round holds the menu bar expanded at the click (it collapses first,
~70–90 ms), ~140 ms when the click comes during a round's screenshot. Outliers up to ~0.75 s remain when the click
follows a round's collapse closely: the lift itself, or the drop after the mouse-up, then occasionally takes ~0.5 s.

## Off-screen moves (both directions): feasible or not, alternatives

- **An off-screen mouse-down routed by position is neither feasible nor safe.** Warping the cursor to X's center
  (−3472.5, 19.5) clamps it to **(0, 19)**, which is Window Server's `Menubar` (layer 24) or the Dock, i.e. the Apple
  menu area. The events were not posted, for safety.
- **With windowID routing (`0x33`), off-screen moves work in both directions**. All cases below succeeded; the
  mouse-down was physically on the spike's own visible Icon or X:

| Case | Result |
|---|---|
| Off screen → on screen: X (−3487) → right of Icon, down on Icon | Success, order correct after 33–36 ms, settled at 430 ms |
| On screen → an **exact** off-screen position: X → right of Y (Y at −8532, endpoint (−8504, 19.5)) | Success, `[Y][X][AH]…` |
| Off screen → off screen: X (between Y and AH) → left of H (endpoint (−3457, 19.5)), down on Icon | Success, settled after 94–152 ms |
| Original plan (position routing), on screen to an off-screen endpoint | Also succeeded: the endpoint uses the raw coordinates |

- **The alternative (temporary expansion) was verified to work but is no longer needed**: temporarily enter
  expandedAll → wait to settle → rescan → move → return to collapsed. Both directions succeeded.
  - 2.4–2.6 s per move in the spike (with generous waits).
  - The practical minimum is about 0.12 s (expand settle) + 0.08 s (events) + 0.45 s (animation) + 0.12 s (collapse)
    ≈ 0.8 s.
  - The menu bar flashes (the temporary expansion the Frost Bar uses to fill in missing images now happens under a
    freeze frame, see `MenuBarFreezeFrame`).

## Clicks: AXPress vs CGEvent (menus and popovers)

| Target | AXPress (cross-process, from a child process) | CGEvent left down/up (no modifiers, session tap, clickState=1) |
|---|---|---|
| X (NSMenu, visible when expanded) | The menu **opens at the correct position**. But `AXUIElementPerformAction` **blocks for about 1.5 s and returns `kAXErrorCannotComplete (−25204)`**, because the menu enters its tracking loop and the AX reply is stuck | The menu opens at the correct position. Same result with or without the window fields |
| Y (NSPopover, visible in expandedAll) | Success, err 0, returns after about 100 ms, action fires | Success, the action fires on mouseUp |
| X, pushed off (collapsed) | The action fires, but **the menu appears off screen**: `x=-3491`, window `onscreen=true` but invisible | Not feasible (position routing, skipped) |
| Y, pushed off (collapsed) | The popover appears but is **clamped to the left screen edge** (x ≈ 58–121), at the wrong position | Not feasible |

- Menu position: the menu window frame is `(item.minX − 4, 40, 63, 34)`, i.e. 1 pt below the 39 pt menu bar,
  left-aligned with the item.
- Popover position: window `(1369, 31, 226, 106)`, horizontal center = Y's midX (1482), top edge overlapping the bottom
  of the menu bar (the arrow).
- Note: calling AXPress on **this process's own** element short-circuits in-process on the calling thread. The result
  is either −25200 (the menu does not open) or a **trap** when a `@MainActor` action is invoked on a background thread.
  So the spike calls it through a child process, `menubar-spike --axpress <pid> <midX>`. This is only a spike problem;
  Frost presses other apps' items, which is cross-process anyway.
- **Conclusion**: both methods work for visible items. **Hidden items must be moved on screen before clicking**:
  AXPress does fire, but the popup appears at the wrong position or off screen.

## Dismissal detection: layer/owner of new windows, is the baseline approach viable?

| | NSMenu | NSPopover |
|---|---|---|
| layer | **101** | **25** (same as status items) |
| owner | **the app itself** (pid of `menubar-spike`, not Control Center) | **the app itself** |
| First appearance (100 ms polling) | 102–109 ms | 100–110 ms (the window first appears small; `popoverDidShow` after about 0.5 s) |
| Gone after closing | `menuDidClose` fires about 240 ms after `cancelTracking()`; the window leaves the on-screen list ≤ 230–330 ms after the call | `popoverDidClose` fires about 0.5 s after `performClose` (closing animation); the window disappears after about 0.54 s. It shrinks to 1×1 while closing |
| windowID | New every time | **The same NSWindow is reused** (same ID each time it is shown). It is not in the on-screen list after closing, so it still counts as a new window next time |

- **The "new window outside the baseline appears → disappears" approach works**, provided windows are filtered.
- **Filtering is required**: within the 3 s window after a click, these unrelated new windows were observed:
  - Notification Center (layer 21, full screen)
  - UserNotificationCenter (layer 8, notification banner)
  - A regular window of a third-party app (layer 3, 1200×1130)
  - Window Server's `StatusIndicator` (layer 2147483630)
- **The predicate planned for Task 11, `isMenu || (isOwnedByItemApp && layer != 25)`, misses popovers** (a popover is
  layer 25). On macOS 26 all status item windows are owned by Control Center, so any window with "owner == pid of the
  clicked app" should count as a popup, including layer 25.
- A `menu.cancelTracking()` scheduled in advance with `DispatchQueue.main.asyncAfter` fires normally inside the menu's
  nested tracking loop.
- "An unrelated menu open at the same time" was **not constructed and was skipped**.
- The menu owner for Control Center's own items (Wi-Fi etc.) was not tested (the safety rules forbid clicking them).

## Crowded menu bar: items still invisible in expandedAll

With the spike's 6 items added, the main display's menu bar row had 20–21 status item windows in total, and
**3–4 of them were still invisible in expandedAll**:

- 3 `Item-0` windows at x = 907 / 945 / 983, under the notch (790–1010), `onscreen=false`.
- 1 `Item-0` at x = 1021 (to the **right** of the notch, so geometrically on screen), yet still hidden by the system:
  `onscreen=false`.

The displayable area is roughly x ≥ 1057 up to Clock (1658–1802).

Conclusions:

- Visibility must be taken from `kCGWindowIsOnscreen`, not from geometry alone.
- New, unseeded items are placed at the far left, so on a notched display they land directly under the notch. In this
  test the spike's V/X/Y/AH did exactly that.

---

## Impact on later tasks

**Task 3 (model)**
- Add `isOnScreen: Bool` to `MenuBarItem` (from `kCGWindowIsOnscreen`); later tasks rely on it to tell "pushed off /
  covered by the notch" apart from "visible".

**Task 4 (StatusWindowParser)**
- Parse `kCGWindowIsOnscreen`.
- Keep windows with width 0 and `onscreen=false` (pushed-off items need them).
- Filter leftover windows of apps that have quit: the window has no match in AX, and is `onscreen=false` with width 0.

**Task 5 (DisplayFilter)**
- The existing rules were verified correct on this machine: top edge aligned with the main display; drop items whose
  center lies on another display; keep pushed-off items with negative x.
  - Items covered by the notch still have their center inside the main display and are kept, which is correct.
- Add a test case: an item with `onscreen=false` whose frame lies inside the main display (under the notch) must be
  kept.
- A secondary display to the left of the main one could not be verified. A pushed-off replica on the secondary display
  sits at x ≈ −1569 and might fall inside a display on the left. Suggestion: add a condition that the window height
  equals the main display's menu bar height (here 39 on the main display, 30 on the secondary) to tell replicas apart.

**Task 6 (AXItemMatcher)**
- midX ± 4 pt works for both regular items and separators.
- A separator's AX width is length + 2 (x inset by 7), so do not match by width.
- Pushed-off items also have negative x positions in AX and match normally.

**Task 7 (SectionAssigner)**
- A separator still has a 16 pt wide window at length 0 and can serve as the boundary.
- AH may be under the notch (`onscreen=false`); section assignment only needs the x coordinate.

**Task 8 (MoveDestination / DropResolver)**
- The endpoint formulas are unchanged: `leftOf → (T.minX + 1, T.midY)`, `rightOf → (T.maxX − 1, T.midY)`.
- **When the target is off screen (negative x), use the raw coordinates as they are**; do not clamp them on screen.

**Task 9 (Scanner)**
- **Do not use `button.window.windowNumber`**: it is not a CG ID, and converting it to `CGWindowID` crashes.
- Identify Frost's 3 control items on the main display by `kCGWindowName == autosaveName` (`FrostIcon` /
  `FrostHiddenSeparator` / `FrostAlwaysHiddenSeparator`); alternatively match `button.window.frame` converted to CG
  coordinates exactly.

**Task 11 (ItemMover): switch to windowID-routed events and drop the temporary expansion**
- `postCommandDrag` becomes:
  - Every event sets `e.setIntegerValueField(CGEventField(rawValue: 0x33)!, value: Int64(item.windowID))`, flags
    `.maskCommand`, posted to `.cgSessionEventTap`.
  - **The mouse-down is physically at the center of Frost's own icon**: it is always visible and it is Frost's own
    item. Even if routing degrades to position-based, the worst case is dragging Frost's own icon; a third-party item
    is never touched.
  - No dragged steps needed: down → `usleep(50_000)` → mouseUp at the endpoint (raw coordinates, may be off screen).
  - Optionally keep Ice's `setLocalEventsFilterDuringSuppressionState(.permitAll…)`.
  - The events take about 80 ms in total, followed by `CGWarpMouseCursorPosition(saved)`.
- Waiting after a move: poll every 25 ms until `isSatisfied` (measured 32–40 ms), then keep polling until two frames
  agree (≤ 540 ms on screen, ≤ 150 ms off screen). Timeout 1 s.
  - `settleDelay` becomes "50 ms initially, then poll" instead of a fixed 150 ms × attempt.
  - Keep `maxAttempts = 3`, and wait for frames to settle before retrying (1 failure was observed; the retry
    succeeded).
- **Clicks (ItemClicker)**:
  - For visible items, a CGEvent click (no modifiers, `mouseEventClickState = 1`, session tap) works for both menus
    and popovers.
  - AXPress on an NSMenu item blocks for about 1.5 s and returns `.cannotComplete` **even though the menu is already
    open**. Recommendations:
    1. Run AXPress in the background (`Task.detached`) and set `AXUIElementSetMessagingTimeout(element, 0.25)`.
    2. Treat both `.success` and `.cannotComplete` as delivered; **do not send an extra CGEvent click**, or it will
       close the menu that just opened.
    3. Fall back to CGEvent only on `.actionUnsupported`, `.attributeUnsupported`, `.noValue`, `.invalidUIElement`,
       `.failure`.
  - Confirm the item `isOnScreen` before clicking: a hidden item's menu appears off screen, and its popover is clamped
    to the left edge.
- **Dismissal detection**: the predicate of `newPresentationWindows` becomes:

  ```swift
  let isMenu = layer == 101
  let isOwnedByItemApp = ownerPID.map { owner == Int($0) } ?? false
  // On macOS 26 status item windows are owned by Control Center; windows owned by the app itself (including
  // layer-25 popovers) are popups
  return isMenu || (isOwnedByItemApp && layer >= 0 && layer < 1000)
  ```

  - This predicate already excludes the noise windows observed: none of them is layer 101 (21 / 8 / 3 / 2147483630),
    and none is owned by the clicked app.
  - `openTimeout = 1 s` is enough: menus and popovers appear within ≤ 110 ms.
  - A popover's window only disappears about 0.5 s after closing, so a 150 ms polling interval after closing is
    appropriate.

**Task 12 (ItemImageCapturer)**
- Off-screen capture fails (−3811), so only capture items with `isOnScreen == true`; other items keep their old cached
  image, or show a placeholder icon otherwise.
- Image size = point size × 2 (29×39 → 58×78). The first capture takes about 100 ms, later ones 25–30 ms.
- Refresh images of visible items opportunistically after every section expansion (including when the layout editor
  opens) to warm the cache.
- Items covered by the notch can never be captured and need a placeholder (app icon + name).

**Task 13 (SectionController)**
- Seeds (written only when the key does not exist):
  - `NSStatusItem Preferred Position FrostIcon = 0`
  - `NSStatusItem Preferred Position FrostHiddenSeparator = 1`
  - `NSStatusItem Preferred Position FrostAlwaysHiddenSeparator = 10000`
  - Alternatively leave AH unseeded; the effect is the same (it lands left of all existing items), but writing 10000
    explicitly is more deterministic.
  - Effect: on first launch Icon sits right next to Control Center's items on their left, and all existing
    third-party items end up between H and AH, i.e. in the Hidden section. Do not give AH a small value, or all
    existing items end up in the Always Hidden section.
  - The creation order stays Icon → H → AH.
- **Do not call `removeStatusItem` on quit**: it deletes the Preferred Position. If an item really must be removed,
  follow Ice and cache the value first, then write it back.
- `controlWindows`: build it from CG title == autosaveName; windowNumber is unusable.
- **Settle wait**: a length change takes effect after 55–61 ms and settles after 108–118 ms. `temporarilyExpand`
  should poll every 50 ms until two scans agree (minimum 100 ms, timeout 500 ms); with a fixed delay, use **150 ms**.
- The collapsed `length = 10_000` actually yields a 5016 pt wide window, enough for menu bars up to about 5000 pt
  wide; the wide separator does not intercept clicks on the app menus.
- In the expanded state H (length 0) leaves a **16 pt gap**. Acceptable; or use Ice's constraint trick: deactivate the
  `NSStatusBarContentView.width == button.superview.width + 16` constraint, then `setContentSize(width: 1)` to get
  1 pt. The editing state reactivates the constraint and sets length 8 (24 pt window).
- On a crowded notched display AH is likely under the notch, so its divider line in the editing state is invisible.
  The layout editor must not rely on seeing AH in the menu bar.

**Task 15 (layout editor)**
- Moves use the windowID routing from Task 11, **no section expansion needed first**; items off screen or under the
  notch can be moved too.
- Capturing does need visible items, so opening the editor first enters editing (both separators at length 8,
  everything expanded) and then captures. After a drop, wait for frames to settle as above, then rescan.

**Task 16 (Frost Bar)**
- Capture: items in `capturer.missing` need a `temporarilyExpand` before capturing; items under the notch use a
  placeholder icon.
  - Later fix: the temporary expansion made the menu bar flash (user feedback). Now images are filled in from the disk
    cache first (`ItemImageDiskCache`), and only items still missing are expanded under a freeze frame (a screenshot of
    the menu bar shown in a click-through window at layer 26), for about 0.5 s, invisible to the user; if the freeze
    frame capture fails, nothing is expanded. Items that still cannot be captured after expanding are not retried until
    the layout / display configuration changes (`CaptureRetryPolicy`).
- Activation flow (move out → click → move back):
  - **Remove `temporarilyExpand(.expandedAll)` from steps 3 and 7.** Moving out from off screen and moving back to the
    original position (including exactly next to an off-screen neighbor) were both verified.
  - After moving out, **wait until frames settle (about 450 ms of animation) before rescanning and clicking**: the
    click or AXPress position must be the final one, or the menu opens at a mid-animation position. (Later refined:
    the item itself doesn't animate; only the windows left of it do. Clicking once the item has landed in its slot is
    enough, see "Later measurement (VM, macOS 26.6.2; Frost Bar click latency)".)
  - Move back using the original anchor; off-screen coordinates can be used directly.
- AXPress does fire for hidden items, but the menu appears off screen or the popover is clamped to the left edge, so
  the "move out" step cannot be skipped.

**Task 10 / 14 / 17**: no impact.

### Not verifiable on this machine
- ~~Whether pushed-off replicas fall inside a secondary display placed to the **left** of the main display.~~
  Verified in the VM together with the "active menu bar", see the next section.
- ~~Which display AX positions refer to when the "active menu bar" moves to the secondary display.~~ Same as above: AX
  follows the active menu bar together with the real windows.
- Menu bars wider than about 5000 pt: whether `length = 10_000`, truncated to 5016 pt, still clears them completely.
- An unrelated menu open at the same time.
- Menu owners and AXPress behavior for third-party or Control Center items (the safety rules forbid operating other
  apps' items).

---

## Multiple displays

Measured in the VM on 2026-10-01.

Environment: VM `frost-test` (macOS 26.6.2, main display 1728×1117, 30 pt menu bar) + a second display added inside
the guest with `CGVirtualDisplay` (`scripts/vm/guest-virtual-display.m`, 1920×1080 / 5120×1440, also a 30 pt menu
bar), placed to the right, to the left, very wide to the left, and below; FakeItems A + B and Frost running. Window
lists from `dump-status-windows.swift --all`. Method: see `docs/testing-vm.md`.

- **Every status item has one window on each display's menu bar** (all layer 25, owner Control Center).
  - **Real window**: this is `button.window`; its title is the autosave name (`FrostIcon`, `Item-0`, `Clock`, …), and
    the AX frame describes it too.
  - **Replicas**: the windows on the other displays, titled with the bundle ID (`dev.frost.FakeItems`,
    `com.apple.Spotlight`; the pid for processes without a bundle), and empty for Control Center's own items (clock,
    Control Center). Their windowIDs have no fixed relationship to the real window (adjacent when created at the same
    time; created in a batch when a display is connected later).
- **The real windows are on the display with the active menu bar, which is not necessarily the main display
  (`CGMainDisplayID()`).** Clicking the secondary display's menu bar (including clicking a status item replica on it)
  or moving focus to that display makes the real windows and the replicas **swap positions**; windowIDs and titles move
  with the windows. When a replica is clicked, the swap is complete before the action reaches the app: the
  `button.window.frame` / `.screen` read in the action already refer to the clicked display. When focus returns to a
  window on the main display, they swap back.
- **A replica = the real window shifted by a fixed per-display offset, with the same width**: right-aligned, offset =
  `D.maxX − A.maxX` (exactly equal in the VM; off by 2 pt on a real Mac with an external display to the right of the
  notched one). Pushed-off items are pushed off "in their own coordinates" on each display:
  - Same-height 1920 display on the right: real `−4015 … −3607`, replicas `−2095 … −1687` (+1920), all outside every
    display rectangle, interleaved;
  - On the left (−1920…0): replicas pushed off to `−5750 … −5335` (−1728), also outside the rectangles;
  - Very wide on the left (−5120…0): the **real** pushed-off items `−4022 … −3607` fall inside its rectangle;
  - Below (y 1117): replicas on their own row (y = 1117), offset +192.
- **The only width difference**: at length 0, the real window of Frost's separator is narrowed to 1 pt by the
  constraint trick while the replica stays 16 pt (the trick only affects `button.window`), so the items to its left are
  shifted 15 pt further on the replica (another 15 pt left of AH when fully expanded). Collapsed (5016) and editing
  (24) widths are identical.
- Each row is a **contiguous** run (each item's maxX = the next item's minX) up to the display's right edge.
- Text items that change width (FakeItems `net` mode grows / shrinks every second): 3,497 samples every 5 ms over 30 s;
  the widths and offsets of real windows and replicas **never** disagreed.
- Resulting implementation: `MenuBarDisplayResolver` (active display = the display holding the real window of Frost's
  icon; replicas on same-row, same-height displays are paired by per-segment offset and removed, unpaired ones are
  judged by contiguity), and `DisplayFilter.axItems` (by row, not by x range).
