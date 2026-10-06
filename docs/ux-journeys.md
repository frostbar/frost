# UX journeys

End-to-end walks through Frost as a user experiences it, run in the VM from a clean state. They complement
[`manual-test-checklist.md`](manual-test-checklist.md): the checklist asks "does each feature work?", a journey asks
"how does it feel to get from A to B?". Extra clicks, windows that vanish or open behind other apps, prompts that
linger, state that doesn't update, dead ends, and text that assumes knowledge the user doesn't have all slip through
feature checks, because every step works on its own.

Why this exists: VM tests used to start with every permission granted by a script and check one feature at a time. As
a result, nobody noticed that "Grant Access" in Settings opened a second window that needed another click, or that
Settings disappeared after the Screen Recording relaunch. A user found both.

## When to run

- **Before every release:** all journeys.
- **After changing a user-facing flow:** the journeys it touches (permissions, onboarding, Settings, the Frost Bar,
  the snowflake menu, updates). If a change adds a new entry point or flow, add or extend a journey in the same
  change.

## How to run

All of this happens in the VM ([`testing-vm.md`](testing-vm.md)); never on the development machine's desktop.

**Clean states.** Each journey names the state it starts from:

| State | How to get it (in the guest unless noted) |
| --- | --- |
| Fresh install | Quit Frost; `defaults delete dev.frost.Frost`; from the host, `scripts/vm/vm-grant-tcc.sh --revoke`; deploy |
| No permissions, onboarding done | As above, then launch, and close onboarding with **Not Now** |
| Accessibility only | Host: `scripts/vm/vm-grant-tcc.sh --revoke screen`; relaunch Frost |
| Everything granted | Host: `scripts/vm/vm-grant-tcc.sh`; relaunch Frost |
| Previous release installed | Host: `gh release download v<previous> -R frostbar/frost -p '*.dmg'`; install it in the guest; grant permissions; arrange a layout |

**Grant permissions the way a user does.** In permission journeys, use the real switches in System Settings
(password: see `testing-vm.md`), not the TCC script. The script skips the system prompts and the distributed
notifications that Frost reacts to, and those are exactly where friction hides. Use the script only to set up a
journey's start state.

**Vary the environment.** Run each journey at least once in Light and once in Dark Mode, and the permission and
Settings journeys once in zh-Hans (launch Frost with `--args -AppleLanguages '(zh-Hans)'`). Use FakeItems for
third-party icons, including the text items (a counter, a percentage).

**Evidence.** Take a screenshot at every step that changes what is on screen, and keep the log stream open
(`make vm-logs`). Keep screenshots outside the repository and refer to them by file name in the report.

## What to look for at every step

- **Clicks:** how many clicks from intent to result? Is any click only a stepping stone ("click to open a window,
  then click again")?
- **Windows and focus:** what is frontmost afterwards? Did a window open behind another app, close unexpectedly, or
  fail to come back after a relaunch?
- **System prompts:** does a system dialog appear together with something else, end up behind System Settings, or
  reappear after the user already answered it?
- **Feedback:** does something visible happen within a moment of every click? Does the status (Granted, Needs
  Relaunch) update without reopening the window?
- **Stale state:** does Frost act on old information (permissions, layout, display) right after the user changed it
  elsewhere?
- **Dead ends and recovery:** after Deny, Not Now, Esc or a mistake, can the user get back on track without knowing a
  hidden trick? Does any notice describe a problem without offering the action that fixes it?
- **Text:** truncation (zh-Hans especially), wording that is inaccurate in the current state, and inconsistent labels
  for the same action.
- **Appearance:** contrast and layout in Light and Dark Mode.
- **Motion:** flicker, jumps, slowness, and anything moving that the user didn't cause (the menu bar expanding,
  icons shifting).
- **Surprises:** things the user may find alarming without an explanation (the purple screen-recording dot, the
  pointer moving).

## Journeys

Each journey lists its start state, its steps, what a good experience looks like, and what has gone wrong there
before. When you fix a finding, add it to "Watch for" so the next run checks it.

### J1. First launch

**Start:** fresh install.

1. Launch Frost. Onboarding appears in front, centered.
2. Grant Accessibility: one click shows the system prompt, which leads to System Settings with Frost listed. Turn on
   the switch. The card turns Granted within a second or two, without switching back to Frost.
3. Grant Screen Recording the same way. The card shows Needs Relaunch, and Relaunch becomes the default button.
4. Relaunch. Frost comes back with onboarding in front, both cards Granted.
5. Finish (Done / Open Layout Editor) and check where each one leads.

**Watch for:**
- The system prompt staying behind System Settings and resurfacing after the grant.
- Relaunch not being the obvious next step while a relaunch is pending.
- Onboarding coming back behind other apps after the relaunch.

### J2. Not now, no permissions

**Start:** no permissions, onboarding closed with Not Now.

1. Click the snowflake, then ⌥-click it: hidden icons expand in the menu bar; nothing is broken.
2. Right-click the snowflake: the menu offers Grant Access….
3. Open Settings: no tab expands the menu bar; every tab that needs Accessibility says so and offers Grant Access.
4. Grant Accessibility from one of those places and click the snowflake right away: the Frost Bar opens (if that is
   the display mode).

**Watch for:**
- Notices without a button.
- The layout editor expanding the whole menu bar when it can't edit.
- The snowflake using a stale permission state after the grant.

### J3. Accessibility only

**Start:** Accessibility only.

1. Open the Frost Bar; every icon is recognisable (app icon, or full text for text items); click, right-click and
   ⌥-click icons.
2. Open the layout editor; drag an icon between sections.
3. Follow the Screen Recording hint in the Frost Bar and in the editor: one click requests the permission; after the
   grant, Relaunch is offered in place.
4. Relaunch from each of those places: Frost comes back with the window you were in.

**Watch for:**
- Truncated text tiles ("4…" for "42%").
- Hints that open the first-run onboarding window instead of acting directly.

### J4. Screen Recording: grant, deny, relaunch

**Start:** Accessibility only, Settings → About open.

1. Grant Access for Screen Recording, then **Deny** the system prompt: the user can still reach the System Settings
   pane in one click.
2. Turn on the switch in System Settings and use its own **Quit & Reopen**: Frost comes back with Settings on About,
   showing Granted.
3. Repeat with Frost's Relaunch button.
4. Quit normally with nothing pending, and launch again: no window reopens.

**Watch for:**
- A Needs Relaunch state with no way back to System Settings.
- Settings not reopening after a relaunch.

### J5. Losing permissions

**Start:** everything granted.

1. In System Settings, remove Frost from the Accessibility list with **−**. Use Frost (snowflake, Frost Bar,
   Settings): it degrades gracefully and says what is missing.
2. Grant Access again: the user never lands on a pane where Frost isn't listed.
3. Same for Screen Recording (the change applies after a relaunch).
4. Turn a switch off instead of removing the entry, and repeat.

**Watch for:**
- Any path that opens System Settings without Frost in the list.

### J6. Daily use: the Frost Bar

**Start:** everything granted, display mode Frost Bar, several hidden and always-hidden icons.

1. Open the Frost Bar; images are current (clocks tick).
2. Click an icon: its menu opens in the menu bar, the pointer moves to it once and stays.
3. Dismiss the menu and move away: the icon goes back within about a second and the snowflake is where it was.
   Click the snowflake's usual spot right away: the Frost Bar opens.
4. While the pointer rests on the forwarded icon, right-click it: its other menu opens.
5. Open a popover-style icon; click outside: the popover closes.
6. ⌥-click the snowflake: Always Hidden icons appear too.

**Watch for:**
- The snowflake staying shifted while an icon lingers.
- The pointer jumping back and forth.
- Flicker in the strip of menu bar above the panel.
- Icons whose tooltip or description shows live numbers (fan speeds, temperatures) or that blink away for a moment
  (an unread-message icon) staying in their sections, without `moved N remembered section(s)` repeating in the log.

### J7. Arranging icons: the layout editor

**Start:** everything granted.

1. Open Settings → Layout: rows open at their leading edge; overflowing rows show fades and paging arrows.
2. Drag icons within and between sections, including to the end of a row that overflows.
3. Close Settings: the menu bar collapses back cleanly.

**Watch for:**
- Rows opening scrolled.
- Drops landing one slot off.
- The menu bar staying expanded after Settings closes.

### J8. Settings tour and persistence

**Start:** everything granted.

1. Visit every tab and change every control once: each change takes effect without reopening anything.
2. Quit and relaunch: settings are kept and Settings reopens on the last tab.
3. Turn launch at login on and off.

**Watch for:**
- Controls that need a relaunch without saying so.
- A tab that always opens instead of the last one.

### J9. The snowflake's menu

**Start:** everything granted, then again with no permissions.

1. Right-click the snowflake and use every item: each one does what it says, and windows come to the front even when
   another app is active.

### J10. Upgrading

**Start:** the previous release installed, with a layout arranged.

Automated by `make vm-upgrade-test` ([`testing-vm.md`](testing-vm.md), "Upgrade test"): it runs the previous release
on a seeded layout with FakeItems until it has stored its state, installs the build over it and checks that it keeps
running without a crash, keeps every icon in its section, keeps the settings, migrates the cached images, doesn't
re-key remembered sections after the first minute, and opens no window by itself. Releases can't be published without
it (`releasing.md`, "Making a release"). Walk the steps below by hand for what it doesn't cover: the Sparkle path, the
look of the Frost Bar, prompts.

1. Install the new build over it: no permission is asked for again, onboarding doesn't reappear, and the layout and
   settings are kept.
2. If the Sparkle path can be exercised (see `releasing.md`, "Testing an update in the VM"), update through it
   instead.

**Watch for:**
- Permissions asked again (expected only when the signing identity changes).
- Icons moving sections after the upgrade, including icons with live numbers in their tooltip or description
  (their identity keys changed format).

### J11. Real Mac only

These can't be reproduced in the VM; run them on a test Mac before releases that touch the related code: a notched
display (icons behind the notch, Automatic mode), an external display (switching the active menu bar), and real
third-party menu bar apps.

## Reporting

List findings as High, Medium or Low. For each finding, give:
- the journey and step;
- what happens;
- why it is friction;
- evidence (screenshot names, log lines);
- a suggested fix.

Keep findings confirmed in the VM separate from suspicions based on reading the code. Also list what could not be
exercised and why. After fixing, add the lesson to the journey's "Watch for", and add new journeys when a run uncovers
a flow that isn't covered.

To hand a run to an agent, point it to this file, `AGENTS.md` and `testing-vm.md`, name the journeys to walk, and ask
for the report above without code changes.

