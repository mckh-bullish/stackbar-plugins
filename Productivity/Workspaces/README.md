# Workspaces

Remembers where your windows go for each monitor setup and puts them back.
Arrange things the way you like at the desk, type "Desk" and press Return;
do the same on the laptop alone. When you plug in or unplug a display (or
wake the Mac on a different set of displays), the starred layout for that
setup comes back by itself, and apps that weren't running are opened.

- **Needs:** `.windows`: the host lists and moves windows through
  Accessibility, so Stackbar asks for Accessibility access the first time.
  Stackbar 0.15.0 or later.
- **Surfaces:** menu bar, panel, settings.
- **Settings:** bring back the starred layout when displays change, open apps
  that aren't running.
- **Commands:** Save Window Layout, Restore Window Layout, and one Restore
  command per layout, so each layout can have its own hotkey or alias.
- **Agent tools:** `layouts`, `save_layout` and `restore_layout`.
- **Not covered:** windows in full screen and on other Spaces, browser tabs,
  snapping and tiling (macOS does that).

## What's new in 1.2.0

- The menu bar icon is off by default: restore layouts from the palette or a hotkey. Settings can keep it on, and it comes back by itself when something needs you.

## What's new in 1.1.0

- Store screenshots now show it in use, with sample data, instead of its first-run screen.

## What's new in 1.0.0

- First release: save your window layout for each monitor setup and get it back when you plug in or undock.
