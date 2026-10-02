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
| `vm-fake-items.sh deploy\|launch [A\|B] [extra] [polite\|net]\|quit\|reset\|log` | build / install / run the FakeItems test apps (`Tools/FakeItems`): `dev.frost.FakeItems` (9 items: menus, 2 popovers, a no-op, the ticking `FIClock`) and `dev.frost.FakeItemsB` (2 items); `extra` adds N more text items; `net` makes `FIClock` show network-speed-like text whose width changes every second (like a network-speed item); every click / menu / popover is logged to guest `/tmp/fakeitems.log` |
| `vm-logs.sh [10m\|1h\|-f]` | `/tmp/frost-stdout.log` plus `log show --info --predicate 'subsystem == "dev.frost.Frost"'`; `-f` streams |
| `vm-grant-tcc.sh [--grant\|--revoke\|--show]` | write/remove Frost's rows in the guest's system TCC.db |
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
| `set-display-profile.swift [icc \| --reset]` | assign a ColorSync profile to the guest display (e.g. the host's "Color LCD", for wide-gamut freeze-frame checks) or reset it |

VNC key mapping (Apple's VNC server): VNC `alt` = ⌘, `meta` = ⌥, `super` = nothing.
The guest has keyboard navigation on (`AppleKeyboardUIMode = 3`), so focus rings show up
on clicked controls in screenshots. The macOS Tahoe "See what's new" notification can sit
over the Frost Bar; close it via Notification Center's AX "Close" action.

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
  `log show --last 10m --info --style compact --predicate 'subsystem == "dev.frost.Frost"'` (or `log stream`).
  Item titles and other user content are logged `.private` (shown as `<private>`).
- Guest look (see "Verification techniques" below): a red/orange gradient
  wallpaper (`~/Pictures/wallpaper-host-like-p3.png`, Display P3) and a built-in Mac display's "Color LCD" profile
  (`~/Library/ColorSync/Profiles/host-color-lcd.icc`). Keep it: a black wallpaper hides shadows and colour shifts
  of anything Frost paints over the menu bar. Reset with `set-display-profile --reset` and the Black.png wallpaper.
- Clicks that must behave like a real user's (activation, focus, clicks on another display's menu bar) should be sent
  from inside the guest as HID-level `CGEvent`s posted to `.cghidEventTap` without the 0x33 window field. VNC input
  behaves differently in places: e.g. choosing "Settings…" from the snowflake menu through VNC activated Frost even
  before the activation fix, while a HID click reproduced the real Mac's "Settings opens behind the front app".
- Multi-display: the guest's virtual display redelivers a *left* click on the inactive display's snowflake replica
  to Frost's button (a real Mac does not), but not a right click. `FROST_TEST_DROP_REPLICA_CLICKS=1`
  (`make vm-run FROST_ENV="FROST_TEST_DROP_REPLICA_CLICKS=1"`) makes Frost drop the redelivered click so the
  replica-click fallback (`ReplicaClickDetector`) can be tested with left clicks too.
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
