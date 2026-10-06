# Changelog

All notable changes to Frost are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/),
and versions follow [Semantic Versioning](https://semver.org/). Each version's section is used verbatim as the
release notes on GitHub and in the in-app update window.

## [Unreleased]

### Changed
- A forwarded icon goes back about 0.75 s after the pointer leaves it (it used to wait 2.5 s while the pointer was
  anywhere on the menu bar), so the Frost icon is back where you expect it. It stays out while its menu is open or the
  pointer rests on it.
- Grant Access buttons (Settings → About, the layout editor, the Frost Bar) ask for the permission right away instead
  of opening the welcome window first. After granting Screen Recording, a Relaunch button appears in place, and Frost
  reopens the window you were in after relaunching (also after System Settings' "Quit & Reopen").
- Settings reopens on the tab you used last, and no longer expands the menu bar while Accessibility is missing.
- Short text icons (a counter, a percentage) now show in full in the Frost Bar and the layout editor without Screen
  Recording. Rows in the layout editor that overflow show edge fades and paging arrows.
- The permission descriptions mention the purple dot macOS shows while Frost captures icons. The grant buttons read
  "Grant Access" everywhere.
- While a relaunch is pending, the welcome window shows it on the Screen Recording card and makes Relaunch the default
  button.
- While a relaunch is pending, the Screen Recording note also offers **Open System Settings** next to **Relaunch**
  (onboarding, About, the layout editor footer and the Frost Bar hint), so denying the system prompt no longer means
  relaunching first to get back to the pane. In the Frost Bar the two actions share a second line under the sentence.

### Added
- The Behavior tab's Accessibility notice has a Grant Access button, and the Frost icon's menu offers Grant Access…
  while Accessibility is missing.

### Fixed
- The system permission prompt no longer lingers behind System Settings and reappears after you granted. Frost
  recognizes it by more than the one process name it uses today, so the pane is not opened on top of it either.
- Clicking the Frost icon right after granting Accessibility opens the Frost Bar instead of expanding the menu bar.
- Icons with live numbers, such as fan speeds or temperatures in their tooltip, now keep their section reliably
  instead of being treated as a different icon every few seconds.
- An icon its app hides and shows again (for example one that blinks for unread messages) goes back to its section
  within a few seconds instead of staying in Always Hidden.
- The Frost Bar no longer closes, and Frost no longer rescans the menu bar, when only the Dock changes size (for
  example when an app's Dock icon appears).

## [0.3.0] - 2026-10-05

### Added
- Icons hidden behind the notch now get real images: while you aren't using the menu bar, Frost briefly moves one
  such icon out under a still image of the menu bar, captures it and puts it straight back (needs Screen Recording).

### Changed
- When you open an icon from the Frost Bar, the pointer moves to it once and stays there, instead of jumping to the
  menu bar and back. The pointer is hidden while Frost moves icons in the background.
- Screen Recording is now optional: with Accessibility alone, the Frost Bar, the layout editor, moving icons and
  keeping them in their sections all work, and icons are shown as their app's icon (or a system symbol) with a short
  label where it helps. Grant Screen Recording to see real images of the icons; a small hint offers it.
- Icons are identified by their Accessibility attributes instead of their window titles. Remembered sections, known
  icons and cached images are moved over automatically.

### Fixed
- An icon moved out for a background capture is always put back, also when you hold the mouse button for a long
  time or quit Frost meanwhile; the still image of the menu bar stays up until it's back.
- Images captured before a Light/Dark Mode switch are refreshed, and failed captures are retried later.

## [0.2.0] - 2026-10-05

Frost is now signed with a Developer ID and notarized by Apple: it opens without the "Open Anyway" step.

**After updating from 0.1.x, grant Accessibility and Screen Recording once more** (System Settings → Privacy &
Security). The signing certificate changed, so macOS treats Frost as a new app this one time; later updates keep the
permissions.

### Added
- Right-click (or Control-click) an icon in the Frost Bar to open its secondary menu; ⌥-click forwards the Option
  key.

### Changed
- An icon opened from the Frost Bar stays in the menu bar while you keep using it (pointer on the menu bar, or a
  second click — e.g. a right click for its other menu) and goes back 2.5 s after the pointer leaves.

### Fixed
- Clicking the snowflake while an opened icon is still in the menu bar opens the Frost Bar on the first click.
- Right clicks on Frost Bar tiles were forwarded as left clicks.

## [0.1.2] - 2026-10-02

### Added
- **Keep icons in their sections**: when an app relaunches and macOS puts its icon in another section (usually
  Always Hidden), Frost moves it back. Icons you move yourself stay where you put them. Turn it off in
  Settings → Behavior.

### Changed
- Clicking an icon in the Frost Bar opens its menu about three times faster.
- Settings is a little taller so every tab fits without scrolling.
- About shows just the version.
- Frost now runs with the Hardened Runtime.

### Fixed
- Dragging icons in the layout editor no longer fails with "Couldn't move…" or lands an icon one slot away from
  where you dropped it.
- Settings content no longer scrolls under the toolbar.

## [0.1.1] - 2026-10-02

A polish release: smoother animations, fewer glitches on notched and multi-display setups, and safer icon moves.

### Changed
- **Settings** uses standard toolbar tabs (Layout, Behavior, About) with a quick cross-fade between them.
- **Frost Bar**: the first open after launch is as fast as later ones; tiles keep their width while the panel is
  open; ⌥-click toggles the Always Hidden section; a plain click always closes the panel.
- Every item in the snowflake menu has an icon, and VoiceOver reads each menu bar icon's own description.
- Scheduled update checks no longer pop up over your work: a dot on the snowflake and an "Update Available…" menu
  item appear instead.
- Frost pauses while the displays sleep, the screen is locked or another user is active.

### Fixed
- The menu bar no longer flickers while the Frost Bar refreshes hidden icons, including over a window right below
  the menu bar.
- The Frost Bar no longer jumps for a frame when its size changes, and items whose width keeps changing (such as
  network speed) no longer make it resize over and over.
- Layout editor: icons no longer jump between sections when it opens on a notched Mac, no "doesn't fit" badges
  flash, tiles show their images from the first frame, and the drag image no longer lingers after a drop.
- Fast drags in the layout editor can no longer carry an icon off the menu bar.
- Quitting Frost never interrupts an icon move, and a forwarded menu's icon always returns to its place.
- Clicking the snowflake on another display works on the first click, also right after connecting it.
- Popovers opened through the Frost Bar close reliably when you click elsewhere, without interrupting your drags
  or menus.
- "Settings…" always brings the window to the front, and Hide Frost (⌘H) works.
- Less disk and CPU work: cached icon images are written at most once a minute, and the menu bar is polled more
  cheaply.

## [0.1.0] - 2026-10-01

First public release.

- **Hide menu bar items** in three sections: Visible, Hidden and Always Hidden. Click the snowflake to show the
  hidden items, ⌥-click to show the always-hidden ones too, with optional auto-rehide.
- **Frost Bar**: a Liquid Glass panel below the menu bar that shows hidden items in a grid and forwards clicks to
  them, with live-updating item images. Used by default on Macs with a notch.
- **Layout editor**: drag items between the three sections using live images of the real menu bar.
- Permission onboarding for Accessibility and Screen Recording, launch at login, multi-display support.
- Automatic updates via Sparkle (can be turned off in Settings → Behavior).
- Available in English and Simplified Chinese.
