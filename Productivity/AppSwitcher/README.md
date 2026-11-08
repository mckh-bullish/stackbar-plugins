# App Switcher

Switch apps without ⌘Tab. Hold **Right ⌘** and press an app's first letter:
S for Safari, X for Xcode. If several apps share a letter, pressing it again
moves to the next one. If only one does and it's already in front, pressing
it again hides it (or shows its next window, if you prefer). Letters with no
app pass through, so Right ⌘ C still copies.

To pin a letter, bring an app to the front and press **Right ⌘ ⌥** plus the
letter. A pinned letter opens the app even when it isn't running. Hold Right
⌘ on its own for a moment to see the whole letter map.

- **Needs:** `.keyLayer` and `.apps`. Stackbar listens to the keyboard and
  switches apps for the plugin, so Stackbar asks for Accessibility access
  the first time. Stackbar 0.21.0 or later.
- **Surfaces:** menu bar, panel, settings.
- **Settings:** the key you hold (Right ⌘, ⌥, ⌃ or ⇧), what pressing the
  letter of the app in front does, the letter map, automatic letters,
  opening pinned apps, and apps left out of the letters.
- **Commands:** Pin a Letter to an App, Clear App Switcher Pins.
- **Agent tools:** `letters`.
- **Not covered:** jumping between Spaces and a window grid. To find an app
  by name, type it in the palette (the Applications plugin); to snap windows,
  use Windows. While an app has Secure Input on, such
  as in a password field, macOS blocks every keyboard listener. The panel
  tells you which app has it on.

## Highlights

### A letter for every app
Hold Right ⌘ and press S for Safari, X for Xcode. Press again to cycle through
apps that share a letter, or to hide the app in front.

### Pin the apps you use most
Right ⌘ ⌥ plus a letter pins the app in front to it. A pinned letter opens the
app even when it isn't running.

### Stays out of your way
Letters with no app pass straight through, so Right ⌘ C still copies. Hold
Right ⌘ on its own to see the whole letter map.

## What's new in 1.3.0

- Pin a Letter to an App takes an app's name, like Slack, and says so when no such app is installed, instead of pinning a letter that does nothing.
- Clearing every pin asks you to click again first, in Settings and in the palette.
- Leave an app out of the letters from its row's menu, and bring it back in Settings.
- If a pinned app can't be opened, the panel says why.

## What's new in 1.2.1

- Checks the key layer once a minute instead of every 20 seconds while idle; launching and quitting apps still update it at once.

## What's new in 1.2.0

- The menu bar icon is off by default, since the switcher lives on a held key. It comes back by itself when the key stops working, and Settings can keep it on.

## What's new in 1.1.0

- Store screenshots now show it in use, with sample data, instead of its first-run screen.

## What's new in 1.0.0

- First release: hold Right ⌘ and press a letter to switch apps, and pin
  letters to the apps you use most.
