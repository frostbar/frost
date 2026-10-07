# GUI testing in an isolated macOS VM

Frost moves and clicks menu bar items, so **GUI tests never run on the host desktop**
(no synthesized events, cursor moves, status items or screen captures on the real
machine). All real-desktop testing happens in a headless [tart](https://tart.run)
macOS 26 VM called `frost-test`. The host only builds the app and talks to the VM
over SSH and the VM's own VNC server.

```
host: make build ──tar/scp──▶ guest /Applications/Frost.app ──open (GUI session)──▶ Frost
host: vncdotool ◀── Virtualization.framework VNC (127.0.0.1) ◀── guest framebuffer
```

## Quick use

```sh
make vm-up                       # boot headless if needed, wait until ready (~20 s)
make vm-deploy                   # make build + install to guest /Applications/Frost.app + TCC grants
make vm-run                      # (re)launch Frost in the guest's GUI session
make vm-run FROST_ENV="FROST_X=1 OTHER=2"
make vm-shot SHOT=/tmp/a.png     # guest screen -> host PNG (default build/vm-shots/shot-<ts>.png)
make vm-logs                     # stdout/stderr + unified log of the Frost process
make vm-down                     # shut the VM down
make vm-upgrade-test             # previous release's real data -> the current build over it (see "Upgrade test")
```

Scripts (all in `scripts/vm/`, each has a usage header):

| script | what it does |
| --- | --- |
| `vm-setup.sh` | one-time provisioning (clone image, CPU/RAM/display, SSH key, display mode). Idempotent. |
| `vm-up.sh` | start headless (`tart run --no-graphics --vnc-experimental`) if not running; wait for IP, SSH, auto-login GUI session; close the Terminal window the image reopens at login |
| `vm-deploy.sh [--no-build]` | `make build`, verify signature, copy `Frost.app` to guest `/Applications/Frost.app`, verify signature in guest, run `vm-grant-tcc.sh` |
| `vm-run.sh [-e K=V]... [--quit] [-- args]` | quit Frost (AppleScript quit, then kill), launch with `open -n --env ... --stdout/--stderr /tmp/frost-stdout.log`. Env names must be 2+ chars (`open --env` ignores 1-char names). |
| `vm-exec.sh [cmd]` | run a shell command in the guest as `admin` over SSH; no args = interactive shell; `--gui cmd...` runs it inside the Aqua session via `launchctl asuser` |
| `vm-screenshot.sh [--guest] <out.png>` | default: grab the VM framebuffer through VNC (no guest permissions involved); `--guest`: run `screencapture` in the guest and copy the PNG back |
| `vm-vnc.sh <vncdotool cmds>` | mouse/keyboard input into the VM (e.g. `move 2956 30 click 1`, `key cmd-space`, `type text`). Coordinates are framebuffer pixels = points × 2. |
| `vm-fake-items.sh deploy\|launch [A\|B\|D] [extra] [polite\|net\|live]\|quit\|reset\|log` | build / install / run the FakeItems test apps (`Tools/FakeItems`): `dev.frost.FakeItems` (9 items: menus, 2 popovers, a no-op, the ticking `FIClock`) and `dev.frost.FakeItemsB` (2 items); `extra` adds N more text items; `net` makes `FIClock` show network-speed-like text whose width changes every second (like a network-speed item); `live` adds `FILiveHelp` / `FILiveDesc` (a number in the AX help / description that changes every second) and `FIBlink` (hidden 4 s out of every 20 s), for identity stability tests; `launch D` runs `dev.frost.FakeItemsDemo`, shown as "Menu Extras", a tidy set of 7 items with neutral names and realistic menus (for README recordings); every click / menu / popover is logged to guest `/tmp/fakeitems.log` |
| `vm-logs.sh [10m\|1h\|-f]` | `/tmp/frost-stdout.log` plus `log show --info --predicate 'subsystem == "dev.frost.Frost"'`; `-f` streams |
| `vm-grant-tcc.sh [--grant\|--revoke\|--show] [accessibility\|screen\|post-event]...` | write/remove Frost's rows in the guest's system TCC.db (all three services by default; e.g. `--revoke screen` leaves Accessibility only, to test Frost without Screen Recording; relaunch Frost afterwards) |
| `vm-upgrade-test.sh [--previous TAG] [--build dev\|DMG\|app\|TAG] [--no-build]` | the upgrade test (see "Upgrade test"); `make vm-upgrade-test [PREVIOUS=…] [BUILD=…]` |
| `vm-crash-check.sh [--wait s] [--process name] SINCE` | the crash reports a process (default Frost) left in the guest since `SINCE` (guest clock: epoch seconds from `vm-exec.sh date +%s`, or `"YYYY-MM-DD HH:MM:SS"`), with exception, termination reason and the crashed thread's top frames; exit 1 if there is one. `--wait` waits that long for ReportCrash to write one |
| `vm-down.sh` | `tart stop` (graceful, forced after 60 s) |

Environment overrides: `FROST_VM` (VM name, default `frost-test`), `FROST_VM_USER` /
`FROST_VM_PASS` (default `admin`/`admin`), `FROST_VM_STATE` (default
`~/.local/share/frost-vm`: SSH key, `run.log` with the VNC URL, vncdotool venv),
`FROST_VM_IMAGE`, `FROST_VM_KEEP_TERMINAL=1`.

## How it works

- **Image**: `ghcr.io/cirruslabs/macos-tahoe-base:latest` (macOS 26.6.2, build 25G83).
  About 27 GB to download, 50 GB sparse disk, about 33 GB real disk use. Auto-login
  as `admin`/`admin`, passwordless sudo, Remote Login on, tart guest agent installed,
  **SIP disabled**. A side effect: the guest does not enforce library validation, so a hardened build that a Mac with
  SIP enabled would refuse to launch (e.g. one missing the self-signed library validation exception, see
  `docs/releasing.md`, "Hardened Runtime and entitlements") still runs in the VM.
- **VM config**: 4 CPUs, 8 GB RAM, display 1728×1117 pt (tart config). The guest came
  up at a saved 1024×768@2x mode, so `vm-setup.sh` runs `set-display-mode.swift`
  in the guest to switch permanently to 1728×1117@2x (3456×2234 px framebuffer).
  It persists across reboots. The VM has no notch. tart gives a macOS guest a single display; for multi-display
  tests add a virtual one inside the guest (`guest-virtual-display.m`, below).
- **Commands**: SSH with a dedicated key (`~/.local/share/frost-vm/id_ed25519`),
  installed on first `vm-up` with `sshpass` and the default password, or with `tart exec`
  as a fallback. `tart exec frost-test <cmd>` also works (runs as `admin`).
- **GUI launch**: `open` from the SSH session reaches the logged-in user's
  LaunchServices, so Frost is spawned by launchd (ppid 1) in the Aqua session and is
  its own TCC "responsible process". Don't exec the binary directly from SSH, because
  TCC would then attribute it to sshd.
- **Permissions (automatic, no clicks)**: because SIP is off, `vm-grant-tcc.sh`
  inserts `kTCCServiceAccessibility`, `kTCCServiceScreenCapture` and
  `kTCCServicePostEvent` rows for `dev.frost.Frost` into
  `/Library/Application Support/com.apple.TCC/TCC.db`. The `csreq` column is compiled
  from the deployed app's designated requirement (`identifier "dev.frost.Frost" and
  certificate leaf = H"…"`), so the grant keeps matching after rebuilds as long as the
  build is signed with "Frost Local Signing". `tccd` answers from the changed database right away (it doesn't need a
  restart, and it ignores `SIGTERM` anyway), but a running process keeps its own cached `AXIsProcessTrusted()` answer
  until the `com.apple.accessibility.api` distributed notification that System Settings posts when the user flips the
  switch: the script posts it in the guest's GUI session, so a running Frost's onboarding and layout editor (which
  poll every second) pick up an Accessibility grant or revocation live, as on a real Mac. Screen Recording changes
  still need a relaunch: `CGPreflightScreenCaptureAccess()` only changes in a new process (by design; onboarding asks
  the user to relaunch). It also pushes
  macOS's recurring "…is requesting to bypass the system private window picker"
  screen-capture alert (replayd's `ScreenCaptureApprovals.plist`, not TCC) out to 2099
  for Frost and for SSH-launched `screencapture`. `vm-deploy.sh` runs it on every
  deploy. Use `vm-grant-tcc.sh --revoke` to test the first-run permission flow.
- **Screenshots**: `tart run --vnc-experimental --no-graphics` starts
  Virtualization.framework's VNC server on 127.0.0.1 with a random port and password,
  logged to `run.log`, without opening any window on the host. `vncdotool` (in a
  private venv) grabs the framebuffer, so this needs no guest permissions. `--guest`
  mode uses `screencapture` over SSH, which works because the image pre-grants
  Screen Recording to `sshd-keygen-wrapper`.

## One-time setup

1. Install [tart](https://tart.run) (see its documentation for the current Homebrew tap or
   release tarball). The scripts look for `tart` on `PATH`, then in `~/.local/opt/tart`,
   then in `/opt/homebrew/bin`.
2. `scripts/vm/vm-setup.sh`. This clones the image, configures the VM, boots it
   headless, installs the SSH key and sets the display mode. No VM window opens and
   nothing needs clicking.
3. `make vm-deploy vm-run vm-shot`.

**No manual steps are needed.** If a future image ships with SIP enabled,
`vm-grant-tcc.sh` stops with an error. The fallback is a one-time GUI grant: run
`tart run frost-test` (this opens a window), then enable Frost under System Settings
→ Privacy & Security → Accessibility and → Screen & System Audio Recording. Keep
deploying to `/Applications/Frost.app` with the same signing identity so the grant
sticks. Alternatively, disable SIP once with `tart run --recovery frost-test`, then
`csrutil disable` in the Recovery Terminal.

## Guest-side helpers (copy with `vm_scp`, compile with `swiftc` in the guest, run with `vm_gui`)

| file | what it does |
| --- | --- |
| `dump-status-windows.swift [--all]` | print the status item windows left to right (x, width, onscreen, windowID, title); `--all`: every display's menu bar row (y, height) and the display list — replicas on other displays too |
| `guest-virtual-display.m w h [hidpi] [right\|left\|above\|below\|x,y]` | add a second display to the guest (CoreGraphics' private `CGVirtualDisplay`, like DeskPad); it exists while the process runs. Compile with `clang -fobjc-arc -framework Foundation -framework CoreGraphics`, start it inside the GUI session (`launchctl asuser`, see `vm_gui`) with `nohup … &`. Not in the VNC framebuffer: `screencapture -x -D 2 out.png` in the guest. Clicks there: `guest-click.swift` with guest coordinates |
| `guest-drag.swift x0 y0 x1 y1 [steps] [hold]` | slow drag made of real `leftMouseDragged` events (points). Needed for the layout editor: VNC pointer drags start a drag session but never reach SwiftUI drop targets. To find the tiles, read the Settings window's accessibility tree from a guest process (each tile is an `AXImage` labelled "App — item", with its frame), and check the result the same way: editor drops can be scripted and verified without screenshots |
| `guest-click.swift x y windowID` | Frost's synthetic click (`HIDTAP=1` for the HID tap) |
| `guest-moveclick.swift …` | Frost's ⌘-drag move followed by a click (reproduces known risk (a)) |
| `guest-axpress.swift pid [index]` | list / AXPress an app's menu bar extras |
| `guest-click-latency.swift title tile [--ah] [--dwell s] [--runs n]` | Frost Bar click-to-menu latency: opens the panel with a HID click on the snowflake (⌥ with `--ah`), waits `--dwell` s, clicks the tile whose accessibility label contains `tile` (`--list` prints them), samples the window list every ~4 ms until the menu / popover appears, checks it is anchored at the item's final frame right of the snowflake, closes it and waits for the item to return; one JSON line per run plus a median / p90 summary |
| `guest-cursor-probe.swift hide [--background] \| trace s [file] \| forward tile left\|right file` | pointer facts: whether an inactive process can hide the pointer (with / without `SetsCursorInBackground`; PNGs in `/tmp/cursor-hide-*.png`); a 10 ms trace of the pointer position; a scripted Frost Bar forward (open, rest on the tile, click, Esc, move away, wait for the move back) with a 5 ms pointer trace and event markers. Pair it with `screencapture -v -C -x -V 12 out.mov` to see whether the pointer was visible |
| `guest-demo-drive.swift snowflakeX snowflakeY tile [--list]` | drives the README demo with real HID events: the pointer glides to the snowflake, clicks it, glides to the Frost Bar tile whose accessibility label contains `tile` (`--list` prints them), clicks it, reads the menu, presses Esc and glides away. The README demo is recorded from outside the guest instead (`vm-record-demo.py`, see "README demo GIF"); this is mainly for `--list` |
| `guest-menubar-probe.swift seconds out` | a 10 ms log of Frost's freeze-frame windows (whole bar or not), drag-image windows (layer 500), the pointer and the status item order, written whenever one changes; for checking the background capture of items behind the notch against a recording |
| `guest-moveback-click.swift lift <id> x y [delayMs] [holdMs] [timeout] [right]` / `away awayX awayY x y delayMs [holdMs] [right]` | a real HID click on the menu bar timed against a move back: `lift` clicks the moment the item's window is lifted (its frame changes after it sat on screen), `away` moves the pointer off the item and clicks `delayMs` later (sweep ~750–950 ms around the linger's 0.75 s) |
| `guest-interrupt.swift x y delayMs holdMs [timeout] [right]` | waits for the background capture's whole-bar freeze frame, then presses a real HID mouse button at (x, y) for `holdMs` (a click on the frozen snowflake, a button held on the desktop) |
| `guest-sections.swift [--json]` | each status item's Frost section (always-hidden / hidden / visible) from the menu bar's geometry alone (order relative to Frost's three windows, found by title), so it compares any two Frost versions; `--json` adds Frost's control frames and its open normal windows. Used by the upgrade test |
| `guest-frost-state.py` | Frost's persisted state as JSON: the image cache entries (key, title, PNG present), `itemTitles.v1`, the remembered sections, the seen icons and the short defaults. Used by the upgrade test |
| `set-display-profile.swift [icc \| --reset]` | assign a ColorSync profile to the guest display (e.g. the host's "Color LCD", for wide-gamut freeze-frame checks) or reset it |

VNC key mapping (Apple's VNC server): VNC `alt` = ⌘, `meta` = ⌥, `super` = nothing.
The guest has keyboard navigation on (`AppleKeyboardUIMode = 3`), so focus rings show up
on clicked controls in screenshots. The macOS Tahoe "See what's new" notification can sit
over the Frost Bar; close it via Notification Center's AX "Close" action.

## Debug-only test hooks

Environment variables read only by Debug builds (`make build`, which `vm-deploy.sh` installs); a Release build compiles
them out. Pass them with `make vm-run FROST_ENV="NAME=value"`.

| variable | effect |
| --- | --- |
| `FROST_TEST_DROP_REPLICA_CLICKS=1` | drops the click the VM redelivers to the snowflake after a click on its replica on another display, like a real Mac that loses it, so the `ReplicaClickDetector` fallback can be tested with left clicks (see "Notes") |
| `FROST_TEST_NOTCH_PRIMARY_DISPLAY=1` | display mode Automatic treats the primary display as notched (the VM has no notch) |
| `FROST_TEST_FRAME_PROBE=1` | `FrameProbe`: frame timing of settings tab switches, the Frost Bar's opens and the launch warm-up; the distributed notification `dev.frost.Frost.frameProbe` (object = label) starts an idle baseline (see "Verification techniques") |
| `FROST_TEST_OBSCURED_RESTORE_PAUSE_MS=<ms>` | the background capture of items behind the notch pauses that long between the capture and the move back, so `guest-interrupt` can reliably hold a button while the item sits right of the Frost icon |
| `FROST_TEST_NO_SCREEN_CAPTURE=1` | no live refresh rounds and no capture of a forwarded item after its menu closes: the Frost Bar shows the cached images and doesn't capture the screen, so the system's screen-recording indicator stays off (README recordings) |
| `FROST_LIVE_REFRESH_TRACE=1` | logs one timing line per live refresh round (not just the first) and items whose frame changed around a strip capture |

## Upgrade test

`make vm-upgrade-test` starts a build on top of **real data written by the previous release**, the path users take
when they update. (0.3.1 crashed at launch for users coming from 0.3.0 while migrating cached icon images; every VM
check before it had run on data written by the then-current build.)

```sh
make vm-upgrade-test                                       # newest older release -> make build (Debug)
make vm-upgrade-test PREVIOUS=v0.3.0                       # from a given release
make vm-upgrade-test BUILD=build/release/0.3.2/Frost-0.3.2.dmg   # a release candidate (required before publishing)
make vm-upgrade-test BUILD=v0.3.1                          # a published release
scripts/vm/vm-upgrade-test.sh --no-build                   # the existing Debug build; --help for the durations
```

It takes about four minutes plus the build, and exits 0 (passed), 1 (the build under test failed a check) or 2 (the
test couldn't run: VM, download, or the previous release didn't reach the seeded state).

1. **Build under test**: `dev` builds with `make build`; a DMG or a release tag (downloaded once with
   `gh release download` to `build/upgrade-test/releases/<tag>/` and checked against GitHub's digest) is mounted on
   the host to read its version. **Previous release**: `PREVIOUS`, else the newest published release (no drafts or
   prereleases) whose version is lower than the build under test's.
2. **Clean guest state**: quits Frost and FakeItems, deletes `dev.frost.Frost`'s defaults and
   `~/Library/Caches/dev.frost.Frost`, and FakeItems' saved positions.
3. **Seeding the layout without the UI**: release builds have no test hooks, and the old version's layout editor would
   need fragile drags, so the layout is written as `NSStatusItem Preferred Position` values into Frost's and
   FakeItems' defaults before anything launches (smaller is further right, `macos-behavior.md`): FIMenuA, FIStar and
   FBTwo visible; FIWide, FIPopover, FIPercent, FIBolt, FIClock, FIDual, FIExtra0, FIExtra1, FILiveHelp, FILiveDesc and
   FBLeaf hidden; FINoop, FIBeta, FIExtra2 and FIBlink always hidden. Frost's own positions are written too (so it
   doesn't seed its first-run placement), plus `hasCompletedOnboarding`, `displayMode = frostBar` (the VM has no
   notch) and `SUEnableAutomaticChecks = false` (the previous release would offer an update). FakeItems runs with
   `extra 3` and `live`: digits in AX descriptions (FIExtra0…2) and live numbers (FILiveHelp / FILiveDesc) are what
   changed identity keys between versions, and FIBlink is re-added at the far left every 20 s.
4. **Previous release**: installed from its DMG, granted (below), launched next to FakeItems. After 15 s the
   snowflake is clicked through VNC (input into the guest only), the Frost Bar stays open 8 s so live refresh captures
   the Hidden items into the disk cache, and is closed again. At 60 s the test records the layout
   (`guest-sections.swift`), Frost's stored state (`guest-frost-state.py`) and its log, checks that the seeded layout
   is in place, that it remembered sections and cached images, and that it didn't crash, then quits it.
5. **Build under test**: installed over it (a DMG like a drag to Applications, `make build`'s app like
   `vm-deploy.sh`) and launched; after 15 s the Frost Bar is opened once the same way, and it runs for 105 s in total.
6. **Checks** (each prints `ok` or `FAIL`):
   - still running as the same process, and no crash report since its launch (`vm-crash-check.sh`); a crash prints the
     report's exception and crashed thread;
   - every item in the same section as under the previous release (retried for 30 s to ride out a re-added FIBlink
     or an item mid-move), matched by window title, which is the same in every version;
   - the cache migrated: for every test item the previous release had an image of (matched to its new identity key
     through `itemTitles.v1`), an image exists under the new key, and none is left under an old key that changed. The
     only exception is FILiveHelp / FILiveDesc: an image cached under a key with a live number can only be moved while
     the item shows that number again, so a stale entry is expected and counted (the item is captured again under
     its new key);
   - no "moved N remembered section(s)" after the first 60 s (identity churn; 0.3.0 itself logs it every 15–20 s
     because of the live items);
   - the Frost Bar opened and refreshed its images (Accessibility and Screen Recording in effect after the upgrade);
   - `displayMode`, `hasCompletedOnboarding` and Frost's Preferred Positions unchanged, and no Frost window open by
     itself (onboarding didn't reappear).
7. **Result**: a summary; the evidence of every run stays in `build/upgrade-test/runs/<time>/` (`output.txt`,
   `checks.txt`, `old-` / `new-sections.json`, `-state.json`, `-log.txt`, `summary.txt`). A passing **DMG** writes the
   marker `build/upgrade-test/passed/<version>-<build>.txt` (version, build, DMG SHA-256, CDHash, previous release, and
   the commit and source identity from `build-info.txt` next to the DMG, which `release.sh` writes) that
   `release.sh --publish` requires (`releasing.md`, "Making a release").

**Permissions, release vs. dev builds.** TCC keeps one row per service and app, holding the code requirement it was
granted to. Releases are Developer ID signed (designated requirement: Apple's anchor and the Team ID); `make build` is
signed with "Frost Local Signing" (requirement: that certificate's hash). `vm-grant-tcc.sh` compiles the row's
`csreq` from the app installed at that moment, so the test grants after installing the previous release, and again
after installing the build under test **only when the designated requirement differs** (always for a dev build, as on
a user's Mac where a different signature means asking again). A Developer ID release candidate after a Developer ID
release keeps the previous release's rows untouched, so the test also shows that an update keeps its permissions;
the "Frost Bar refreshed its images" check fails if it doesn't.

The test leaves the build under test running with FakeItems; after testing a DMG, `make vm-deploy` puts the Debug build
back. It doesn't cover the Sparkle update path (see `releasing.md`, "Testing an update in the VM"), Gatekeeper's
first-launch prompt for a downloaded copy (the copy isn't quarantined), the look of the Frost Bar, or data the
previous release only writes after user actions the test doesn't make (layout editor drops, ⌘-drags, items behind a
notch).

## Notes

- The VM keeps running headless between sessions. `tart list` shows its state and
  `make vm-down` stops it. `vm-up.sh` is safe to call any time.
- Disk: about 33 GB real use (`~/.tart/cache` OCI image plus the `frost-test` clone,
  which share blocks). `tart delete frost-test` and `tart prune --entries=caches`
  reclaim it.
- Reset the guest to a pristine state: `tart delete frost-test && scripts/vm/vm-setup.sh`
  (the image is cached, so there is no re-download).
- Frost logs through `os.Logger` (`FrostLog`, subsystem `dev.frost.Frost`, one category per area: `app`, `sections`,
  `scanner`, `mover`, `capture`, `frostbar`, `freezeframe`, `activation`, `layout`, `newitems`). It does not
  write to stdout/stderr any more, so `/tmp/frost-stdout.log` only has crashes and system noise; `vm-logs.sh` shows
  the unified log. The same command works on a real Mac, where Frost runs with stderr = `/dev/null`:
  `/usr/bin/log show --last 10m --info --style compact --predicate 'subsystem == "dev.frost.Frost"'` (or
  `/usr/bin/log stream`; in zsh a bare `log` is a builtin).
  Item titles and other user content are logged `.private` (shown as `<private>`).
- Guest look (see "Verification techniques" below): a red/orange gradient
  wallpaper (`~/Pictures/wallpaper-host-like-p3.png`, Display P3) and a built-in Mac display's "Color LCD" profile
  (`~/Library/ColorSync/Profiles/host-color-lcd.icc`). Keep it: a black wallpaper hides shadows and colour shifts
  of anything Frost paints over the menu bar. Reset with `set-display-profile --reset` and the Black.png wallpaper.
- Clicks that must behave like a real user's (activation, focus, clicks on another display's menu bar) should be sent
  from inside the guest as HID-level `CGEvent`s posted to `.cghidEventTap` without the 0x33 window field. VNC input
  behaves differently in places: e.g. choosing "Settings…" from the snowflake menu through VNC activated Frost even
  before the activation fix, while a HID click reproduced the real Mac's "Settings opens behind the front app".
- Every `vm-vnc.sh` call is a new VNC session whose pointer starts at (0, 0): a `click` without a `move` in the same
  call lands in the top-left corner (the Apple menu). Put `move x y` before every click, or chain the steps in one
  call with `pause`.
- Multi-display: the guest's virtual display redelivers a *left* click on the inactive display's snowflake replica
  to Frost's button (a real Mac does not), but not a right click. `FROST_TEST_DROP_REPLICA_CLICKS=1`
  (`make vm-run FROST_ENV="FROST_TEST_DROP_REPLICA_CLICKS=1"`) makes Frost drop the redelivered click so the
  replica-click fallback (`ReplicaClickDetector`) can be tested with left clicks too.
- Settings window height: the window's height follows the selected tab (the Layout tab has a fixed height, the others
  are as tall as their content) and animates on a tab switch. To drive a switch, click the toolbar tabs with HID-level
  events from inside the guest (`guest-click.swift`, `HIDTAP=1`, window ID 0) and read the `frame-probe tab-<name>`
  lines; record the window with `screencapture -v -R…` and split the movie with `ffmpeg` to check that the toolbar
  and content never jump.
- Display mode Automatic: the VM has no notch, so Automatic expands in the menu bar on every display.
  `FROST_TEST_NOTCH_PRIMARY_DISPLAY=1` (Debug builds) makes Automatic treat the primary display as notched: the Frost
  Bar on the main display and In Menu Bar on the virtual one, like a notched Mac with an external display.

## Verification techniques

Methods that proved necessary for the parts of Frost that paint over the menu bar (the freeze frame) or depend on
timing. Evidence (recordings, logs, analysis scripts) goes under `build/vm-shots/<topic>/`, which is gitignored.

- **Freeze frame / "the menu bar flickers"**: never judge on a black wallpaper, where shadows and colour shifts are
  invisible. Use a colourful gradient wallpaper (Display P3) and a wide-gamut display profile
  (`set-display-profile.swift`), put a window right below the menu bar (its shadow shows through the transparent
  menu bar), open the Frost Bar for ~10 s and compare **VNC framebuffer** grabs (`vm-screenshot.sh`) taken with and
  without the freeze frame on screen. ScreenCaptureKit captures cannot be used as ground truth: the freeze frame and
  the real menu bar are pixel-identical there even when the compositor shows a difference. A residual difference of
  ≤ 2 levels on gradients is a known rounding difference.
- **Live refresh / "the menu bar expands visibly"**: record the menu bar in the guest
  (`screencapture -v -x -R0,0,<width>,200`) while polling the window list every ~20 ms (freeze-frame window at layer 26,
  number of on-screen status items), then compare frames left of the snowflake: no frame may show the expansion, and
  every expansion must happen while the freeze frame is on screen. Turn on the clock's seconds to see that the area
  right of the snowflake stays live.
- **Background capture of items behind the notch**: emulate the notch with many items (`vm-fake-items.sh launch A 30`:
  with the Hidden section full, the items that don't fit stay off screen when expanded), delete the image cache, launch
  Frost, open the Frost Bar once (it records them) and close it, park the pointer on the desktop. Then run
  `guest-menubar-probe` and `screencapture -v -C -x -R0,0,<width>,700` side by side for a minute (both over SSH) and
  compare every frame with the last one, left of the system items: the recording is H.264, so count only pixels off
  by more than ~40 levels (glyph edges differ by up to ~50 between key frames). A real problem shows hundreds to
  thousands of such pixels: an item moving, the snowflake shifting, the lifted item's drag image, or the pointer
  appearing on the menu bar. `dump-status-windows` before and after must list the same order; the parked pointer may
  only blink (hidden for each ⌘-drag). `guest-interrupt` tests a click on the frozen snowflake and a held button.
- **Timing**: don't grab the VNC framebuffer while timing or recording; it slows the guest (clock skips, refresh
  cycles show 0.5–0.8 s outliers). `screencapture -v` only emits frames when the screen changes, so use a probe that
  captures the clock's own window to check that the clock ticks on time. Measure CPU from the cumulative CPU time in
  `ps` over a 30 s window.
- **Frame timing / "the animation stutters"**: run a Debug build with `FROST_TEST_FRAME_PROBE=1`
  (`make vm-run FROST_ENV="FROST_TEST_FRAME_PROBE=1"`). `FrameProbe` puts a display link on the window for 1.2 s after
  each settings tab switch and logs `frame-probe <label> frames=… firstFrame=… maxGap=… hitches=… hitchTime=… at=…` (a
  hitch is a gap of more than 1.5 refresh periods, i.e. the main thread missed a frame; `at=` lists each hitch as
  `<ms after the switch>+<gap ms>`, which tells hitches during an animation from later work such as the layout editor
  starting). Drive the switches with real HID-level clicks from inside the guest, and get an idle baseline by posting
  the distributed notification `dev.frost.Frost.frameProbe` (object = label) without touching the window. Don't grab
  the VNC framebuffer meanwhile.
- **Frost Bar first open / "the first click looks off"**: the same probe runs on the screen's display link from the
  click on the snowflake for 1.5 s (`frame-probe frostbar-open-<n>`, numbered since launch) and for the launch warm-up
  (`frostbar-warmup`). `firstFrame` is the click-to-panel latency; `notes=` adds checkpoints in ms after the click
  (`cached(images=N)`, `ordered`, `animate`, `resize(…)` if the panel changes size while visible, `cycle` when a live
  refresh round starts), so hitches can be attributed to the 0.18 s animation or to the first refresh round. Compare
  open 1 with opens 2–3 after a fresh launch, with the image cache present and deleted; `sudo purge` in the guest
  before launching approximates the cold start after an update. Click the snowflake with a HID-level event from inside
  the guest and leave the pointer on it (parked over the menu bar left of the snowflake, it pauses live refresh). For
  the look, record the panel area with `screencapture -v -R…` and compare each open's frames: the same number of
  evenly spaced frames, the same opacity ramp and the same final panel bounds.
- **Multi-display**: add a second display with `guest-virtual-display.m` (right, left, very wide on the left, below),
  dump every display's menu bar row with `dump-status-windows.swift --all`, screenshot it with
  `screencapture -D 2` and click on it with `guest-click.swift`. The virtual display has the same 30 pt menu bar as
  the main one, which is the hardest case for telling real windows and replicas apart.
- **Click forwarding latency**: run `guest-click-latency.swift` (needs the panel's items to be FakeItems with known
  window titles, see `dump-status-windows.swift`) for a menu and a popover item in Hidden and in Always Hidden, with
  `--dwell 4` (live refresh running) and `--dwell 0.35` (right after opening, the first round is taking its freeze
  frame). Each forward also logs `click forward of <id>: transaction …, down …, lifted …, up …, landed …, click …` (ms
  since Frost handled the tile click); match the lines to the runs by time (`epoch` is the wall clock of the tile's
  mouse-up) for a breakdown. A ticking clock item next to the snowflake shifts neighbours by a point or two every
  second; that's not a misplaced menu.
- **Popover dismissal timing**: post the outside click from inside the guest and sample the window list every 10 ms
  on the same clock; FakeItems logs every click / menu / popover open and close to `/tmp/fakeitems.log`.
- **README demo GIF** (`docs/images/demo.gif`; retake it when the Frost Bar's look or the click flow changes). Record
  it from **outside** the guest: `screencapture -v` inside the guest makes macOS show its purple screen-recording
  indicator next to the Control Center icon (and shifts the icons), Frost's own captures do the same for a few seconds,
  and neither belongs in the picture. Setup: Light Mode, a calm pastel gradient wallpaper (made with ffmpeg's `geq`,
  copied to the guest and set with System Events), `vm-fake-items.sh launch D` ("Menu Extras", 7 icons with neutral
  names and realistic menus, all in Hidden), both permissions granted. Open the Frost Bar once with a normal run so the
  icons' images are cached, then `make vm-run FROST_ENV="FROST_TEST_NO_SCREEN_CAPTURE=1"` (no live refresh and no
  capture after a forwarded click, so Frost never captures the screen; the panel shows the cached images). Find the
  snowflake (`dump-status-windows`) and the tile's centre (`guest-demo-drive <x> 15 x --list`, in points), then run
  `~/.local/share/frost-vm/venv/bin/python -W ignore scripts/vm/vm-record-demo.py OUTDIR <snowflake x> 15 <tile x> <tile y>`.
  It drives the pointer through VNC input and saves the top-right 480x328 pt region at 25 fps (960x656 px) from the VNC
  framebuffer, which has no pointer: the script pastes an arrow at the commanded position, and after the click moves
  it onto the forwarded item, where Frost leaves the real pointer. VNC capture keeps up (the guest stays smooth, the
  clock doesn't skip) because the script asks for incremental updates from inside the client's reactor thread; calling
  `refreshScreen` from a pump thread serializes with the input calls (0.8 s per pointer move), and per-frame
  `captureRegion` gets 1 fps. Cut the frames from just before the arrow enters to the moment the icon is back (the item
  returns ~0.75 s after the pointer leaves it, plus a fade) and convert with ffmpeg:
  `ffmpeg -framerate 25 -start_number N -i f%05d.bmp -frames:v M -vf "split[a][b];[a]palettegen=max_colors=192:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle" -loop 0 demo.gif`.
  Error diffusion dithering (`sierra2_4a`) makes the smooth wallpaper several times larger.
