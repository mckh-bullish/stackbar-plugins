# Windows

Snap the front window, and save where all your windows go. Type "left half"
in the palette or give any snap a hotkey; arrange things the way you like at
the desk, type "Desk" and press Return, and do the same on the laptop alone.
When you plug in or unplug a display (or wake the Mac on a different set of
displays), the starred layout for that setup comes back by itself, and apps
that weren't running are opened.

Windows used to be two plugins, Workspaces and Window Layouts. If you had
Window Layouts, its hotkeys and aliases move here and it is turned off; you
can uninstall it from its page in Settings.

- **Needs:** `.windows`: the host lists and moves windows through
  Accessibility, so Stackbar asks for Accessibility access the first time.
  Stackbar 0.35.0 or later.
- **Surfaces:** menu bar (off by default), panel, settings.
- **Snapping:** halves, the four quarters, First / Center / Last Third,
  First / Last Two Thirds, Maximize, Almost Maximize, Center, Next Display,
  Previous Display (palette only) and Undo Snap, which puts the window back
  where it was before its last snap. Pressing Left, Right, Top or Bottom Half
  again cycles through two thirds and one third.
- **Settings:** the gap left around snapped windows, bring back the starred
  layout when displays change, open apps that aren't running, cycle sizes on
  repeated halves, and the menu bar icon.
- **Commands:** one per snap, Save Window Layout, Restore Window Layout, and
  one Restore command per layout, so each layout can have its own hotkey or
  alias.
- **Agent tools:** `snap`, `layouts`, `save_layout` and `restore_layout`.
- **Not covered:** windows in full screen and on other Spaces, and browser
  tabs.

## What's new in 2.2.0

- Deleting a layout, or every layout, asks through Stackbar, naming what goes.
- Stackbar 0.35.0 now asks for the second press itself, the same way in the panel, the palette and every window, and VoiceOver reads the question.

## What's new in 2.1.0

- Snap buttons in the panel now say when nothing could move, for example "Only one display" or when an app won't let its window move.
- Restoring a layout saved with a display that's no longer connected keeps every window on a screen you have.
- Deleting a layout, or all of them, asks you to click again first.
- Pressing Left, Right, Top or Bottom Half again cycles the window through two thirds and one third. You can turn this off in Settings.
- New Previous Display command.

## What's new in 2.0.0

- Window Layouts is now part of Workspaces, and together they are called Windows. The panel has a row of snap buttons above your saved layouts, and every snap is still a command.
- Window Layouts' Restore is now Undo Snap, because Restore here brings back a saved layout. Its hotkey doesn't carry over; set it again in Settings › Commands.
- The snap gap starts at None again. Set it in Settings if you had changed it.

## What's new in 1.2.0

- The menu bar icon is off by default: restore layouts from the palette or a hotkey. Settings can keep it on, and it comes back by itself when something needs you.

## What's new in 1.1.0

- Store screenshots now show it in use, with sample data, instead of its first-run screen.

## What's new in 1.0.0

- First release: save your window layout for each monitor setup and get it back when you plug in or undock.
