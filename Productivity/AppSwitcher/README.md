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
  the first time. Stackbar 0.16.0 or later.
- **Surfaces:** menu bar, panel, settings.
- **Settings:** the key you hold (Right ⌘, ⌥, ⌃ or ⇧), what pressing the
  letter of the app in front does, the letter map, automatic letters, and
  opening pinned apps.
- **Commands:** Pin a Letter to an App, Clear App Switcher Pins.
- **Agent tools:** `letters`.
- **Not covered:** jumping between Spaces, a window grid, and searching for
  apps by name (Spotlight does that). While an app has Secure Input on, such
  as in a password field, macOS blocks every keyboard listener. The panel
  tells you which app has it on.

## What's new in 1.0.0

- First release: hold Right ⌘ and press a letter to switch apps, and pin
  letters to the apps you use most.
