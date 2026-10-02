# Changelog

All notable changes to Frost are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/),
and versions follow [Semantic Versioning](https://semver.org/). Each version's section is used verbatim as the
release notes on GitHub and in the in-app update window.

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
